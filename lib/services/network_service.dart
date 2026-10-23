/// Read-only network listing (T6, docs/spec/mcp-tools.md §3.4, ui-ia.md D7).
///
/// Network list goes through the CLI (`container network ls --format json`)
/// because the XPC surface exposes no network enumeration in 1.5/1.6
/// (docs/research/bridge-flutter-apple-container.md). Membership joins
/// against container snapshots' `networks` attachments.
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import '../bridge/container_bridge.dart';
import 'container_service.dart';
import 'errors.dart';

/// One network as reported by `container network ls`.
class NetworkInfo {
  const NetworkInfo({
    required this.id,
    required this.plugin,
    required this.mode,
    this.subnet,
    this.gateway,
    required this.builtin,
    required this.labels,
    required this.containerCount,
  });

  final String id;
  final String plugin;
  final String mode;

  /// IPv4 subnet CIDR (e.g. "192.168.64.0/24"); null when absent.
  final String? subnet;

  final String? gateway;

  /// `com.apple.container.resource.role=builtin` (verified wire label).
  final bool builtin;

  final Map<String, String> labels;

  /// Containers currently attached (from snapshot join).
  final int containerCount;

  Map<String, Object?> toWire() => <String, Object?>{
    'id': id,
    'plugin': plugin,
    'mode': mode,
    if (subnet != null) 'subnet': subnet,
    if (gateway != null) 'gateway': gateway,
    'builtin': builtin,
    'containerCount': containerCount,
  };
}

/// One container attached to a network (for `network_get`).
class NetworkMember {
  const NetworkMember({
    required this.containerId,
    required this.hostname,
    required this.address,
  });

  final String containerId;
  final String hostname;

  /// IPv4 without prefix; empty when absent.
  final String address;

  Map<String, Object?> toWire() => <String, Object?>{
    'id': containerId,
    'hostname': hostname,
    'ip': address,
  };
}

/// `network_get` payload: network fields plus member containers.
class NetworkDetail {
  const NetworkDetail({required this.info, required this.containers});

  final NetworkInfo info;
  final List<NetworkMember> containers;

  Map<String, Object?> toWire() => <String, Object?>{
    ...info.toWire(),
    'containers': containers
        .map((member) => member.toWire())
        .toList(growable: false),
  };
}

/// Lists networks (CLI) and joins container membership (XPC snapshots).
/// Read-only: create/delete stay CLI-side in v1.
class NetworkService {
  NetworkService({
    required ContainerBridge bridge,
    required ContainerService containerService,
  }) : _bridge = bridge,
       _containerService = containerService;

  final ContainerBridge _bridge;
  final ContainerService _containerService;

  static const String builtinRoleLabel = 'com.apple.container.resource.role';

  /// All networks with member counts. Includes `default` even when no
  /// container is attached.
  Future<List<NetworkInfo>> listNetworks() async {
    final raw = await _bridge.networkList();
    _ensureOk(raw, 'network list');
    final infos = parseNetworkList(raw.stdout);
    final containers = await _containerService.listContainers(
      const ContainerQuery(),
    );
    return infos
        .map(
          (info) => NetworkInfo(
            id: info.id,
            plugin: info.plugin,
            mode: info.mode,
            subnet: info.subnet,
            gateway: info.gateway,
            builtin: info.builtin,
            labels: info.labels,
            containerCount: containers
                .where(
                  (container) => container.networks.any(
                    (attachment) => attachment.network == info.id,
                  ),
                )
                .length,
          ),
        )
        .toList(growable: false);
  }

  /// One network plus its member containers ([id] is the network name).
  Future<NetworkDetail> getNetwork(String id) async {
    final networks = await listNetworks();
    NetworkInfo? match;
    for (final network in networks) {
      if (network.id == id) {
        match = network;
        break;
      }
    }
    if (match == null) {
      throw GcmException(
        GcmErrorCode.notFound,
        'Network "$id" was not found.',
        hint: 'Run network_list for the exact name.',
      );
    }
    final containers = await _containerService.listContainers(
      const ContainerQuery(),
    );
    final members = <NetworkMember>[];
    for (final container in containers) {
      for (final attachment in container.networks) {
        if (attachment.network == id) {
          members.add(
            NetworkMember(
              containerId: container.id,
              hostname: attachment.hostname,
              address: attachment.address,
            ),
          );
        }
      }
    }
    return NetworkDetail(info: match, containers: List.unmodifiable(members));
  }

  /// Parses the `network ls --format json` array (wire locked against CLI
  /// 1.5.0: `configuration{name,mode,plugin,labels}` +
  /// `status{ipv4Subnet,ipv4Gateway}`).
  static List<NetworkInfo> parseNetworkList(String stdout) {
    Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } on FormatException catch (error) {
      throw GcmException(
        GcmErrorCode.internal,
        'container network ls returned non-JSON output.',
        cause: error,
      );
    }
    if (decoded is! List) {
      throw const GcmException(
        GcmErrorCode.internal,
        'container network ls returned an unexpected JSON shape.',
      );
    }
    final result = <NetworkInfo>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      final config =
          (map['configuration'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
      final status =
          (map['status'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
      final id = config['name'] as String?;
      if (id == null) continue;
      final rawLabels = config['labels'];
      final labels = rawLabels is Map
          ? rawLabels.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const <String, String>{};
      result.add(
        NetworkInfo(
          id: id,
          plugin: config['plugin'] as String? ?? '',
          mode: config['mode'] as String? ?? '',
          subnet: status['ipv4Subnet'] as String?,
          gateway: status['ipv4Gateway'] as String?,
          builtin: labels[builtinRoleLabel] == 'builtin',
          labels: labels,
          containerCount: 0,
        ),
      );
    }
    return result;
  }

  static void _ensureOk(BridgeCommandResult result, String operation) {
    if (result.exitCode == 0) return;
    throw GcmException(
      GcmErrorCode.internal,
      'container $operation failed (exit ${result.exitCode}).',
      hint: result.stderr.trim().isEmpty ? null : result.stderr.trim(),
    );
  }
}
