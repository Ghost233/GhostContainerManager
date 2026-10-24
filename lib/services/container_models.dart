/// Container domain model for the Service layer (T2a).
///
/// The bridge hands over JSON-decoded `ContainerSnapshot` dictionaries from
/// apple/container 1.6.0; this module turns them into typed, immutable
/// objects. Unknown extra keys are ignored so newer runtime versions do not
/// break the parser.
library;

import 'errors.dart';

/// Runtime lifecycle status (apple/container `RuntimeStatus`).
enum ContainerState {
  unknown('unknown'),
  stopped('stopped'),
  running('running'),
  stopping('stopping');

  const ContainerState(this.wireName);

  /// Raw string as reported by the apiserver / CLI.
  final String wireName;

  static ContainerState fromWire(String? value) {
    return ContainerState.values.asNameMap()[value] ?? ContainerState.unknown;
  }
}

/// One network attachment (`Attachment` in apple/container).
class ContainerNetworkAttachment {
  const ContainerNetworkAttachment({
    required this.network,
    required this.hostname,
    required this.address,
    required this.gateway,
  });

  final String network;
  final String hostname;

  /// IPv4 CIDR without prefix ("192.168.64.3"); empty when absent.
  final String address;

  final String gateway;

  static ContainerNetworkAttachment fromMap(Map<String, Object?> map) {
    return ContainerNetworkAttachment(
      network: map['network'] as String? ?? '',
      hostname: map['hostname'] as String? ?? '',
      address: _parseCidrAddress(map['ipv4Address']),
      gateway: _parseCidrAddress(map['ipv4Gateway']),
    );
  }

  /// `CIDRv4` encodes as either a "a.b.c.d/24" string or an
  /// `{"address": ...}` map depending on the encoder path — accept both.
  static String _parseCidrAddress(Object? value) {
    if (value is String) {
      final slash = value.indexOf('/');
      return slash >= 0 ? value.substring(0, slash) : value;
    }
    if (value is Map) {
      return value['address'] as String? ?? '';
    }
    return '';
  }
}

/// Published port mapping (`PublishPort`).
class PublishedPort {
  const PublishedPort({
    required this.hostAddress,
    required this.hostPort,
    required this.containerPort,
    required this.proto,
  });

  final String hostAddress;
  final int hostPort;
  final int containerPort;

  /// 'tcp' | 'udp'.
  final String proto;

  static PublishedPort fromMap(Map<String, Object?> map) {
    return PublishedPort(
      hostAddress: map['hostAddress'] as String? ?? '',
      hostPort: _asInt(map['hostPort']),
      containerPort: _asInt(map['containerPort']),
      proto: map['proto'] as String? ?? 'tcp',
    );
  }
}

/// Container snapshot as needed by list/inspect (parsed from the bridge
/// payload — see apple/container `ContainerSnapshot`).
class ContainerSnapshotInfo {
  const ContainerSnapshotInfo({
    required this.id,
    required this.image,
    required this.state,
    required this.labels,
    required this.networks,
    required this.createdAt,
    required this.startedAt,
    required this.initCommand,
    required this.initArguments,
    required this.environment,
    required this.publishedPorts,
    required this.stopSignal,
    required this.rawConfiguration,
  });

  final String id;
  final String image;
  final ContainerState state;
  final Map<String, String> labels;
  final List<ContainerNetworkAttachment> networks;

  /// `configuration.creationDate`; null when the payload lacks it.
  final DateTime? createdAt;

  /// `snapshot.startedDate`; null for never-started containers.
  final DateTime? startedAt;

  /// `initProcess.executable` / `.arguments` — the container's entrypoint.
  final String initCommand;
  final List<String> initArguments;

  /// `initProcess.environment` ("KEY=VALUE" strings).
  final List<String> environment;

  final List<PublishedPort> publishedPorts;

  final String stopSignal;

  /// Full `configuration` dictionary, kept for inspect passthrough.
  final Map<String, Object?> rawConfiguration;

  /// Parses one bridge payload entry.
  ///
  /// Throws [GcmException] with [GcmErrorCode.internal] when the payload
  /// misses the minimum identifying fields (a wire-format break).
  static ContainerSnapshotInfo fromMap(Map<String, Object?> map) {
    final config = map['configuration'];
    if (config is! Map) {
      throw const GcmException(
        GcmErrorCode.internal,
        'Container snapshot is missing its "configuration" object.',
        hint: 'The runtime wire format changed; check the container version.',
      );
    }
    final configMap = config.cast<String, Object?>();
    final id = configMap['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const GcmException(
        GcmErrorCode.internal,
        'Container snapshot is missing "configuration.id".',
        hint: 'The runtime wire format changed; check the container version.',
      );
    }

    final image = configMap['image'];
    final imageReference = image is Map
        ? image['reference'] as String? ?? ''
        : '';

    final init = configMap['initProcess'];
    final initMap = init is Map ? init : const <String, Object?>{};

    final networksValue = map['networks'];
    final portsValue = configMap['publishedPorts'];

    return ContainerSnapshotInfo(
      id: id,
      image: imageReference,
      state: ContainerState.fromWire(map['status'] as String?),
      labels: _stringMap(configMap['labels']),
      networks: networksValue is List
          ? networksValue
                .whereType<Map>()
                .map(
                  (n) => ContainerNetworkAttachment.fromMap(
                    n.cast<String, Object?>(),
                  ),
                )
                .toList(growable: false)
          : const [],
      createdAt: _asDate(configMap['creationDate']),
      startedAt: _asDate(map['startedDate']),
      initCommand: initMap['executable'] as String? ?? '',
      initArguments: initMap['arguments'] is List
          ? (initMap['arguments']! as List)
                .map((a) => a.toString())
                .toList(growable: false)
          : const [],
      environment: initMap['environment'] is List
          ? (initMap['environment']! as List)
                .map((e) => e.toString())
                .toList(growable: false)
          : const [],
      publishedPorts: portsValue is List
          ? portsValue
                .whereType<Map>()
                .map((p) => PublishedPort.fromMap(p.cast<String, Object?>()))
                .toList(growable: false)
          : const [],
      stopSignal: configMap['stopSignal'] as String? ?? 'SIGTERM',
      rawConfiguration: configMap,
    );
  }
}

/// One stats snapshot (`ContainerStats`; all counters optional upstream).
class ContainerStatsInfo {
  const ContainerStatsInfo({
    required this.id,
    this.memoryUsageBytes,
    this.memoryLimitBytes,
    this.cpuUsageUsec,
    this.networkRxBytes,
    this.networkTxBytes,
    this.blockReadBytes,
    this.blockWriteBytes,
    this.numProcesses,
  });

  final String id;
  final int? memoryUsageBytes;
  final int? memoryLimitBytes;
  final int? cpuUsageUsec;
  final int? networkRxBytes;
  final int? networkTxBytes;
  final int? blockReadBytes;
  final int? blockWriteBytes;
  final int? numProcesses;

  /// Memory utilisation in [0, 1]; null when either side is missing/zero.
  double? get memoryUtilization {
    final usage = memoryUsageBytes;
    final limit = memoryLimitBytes;
    if (usage == null || limit == null || limit == 0) return null;
    return usage / limit;
  }

  static ContainerStatsInfo fromMap(Map<String, Object?> map) {
    return ContainerStatsInfo(
      id: map['id'] as String? ?? '',
      memoryUsageBytes: _asIntOrNull(map['memoryUsageBytes']),
      memoryLimitBytes: _asIntOrNull(map['memoryLimitBytes']),
      cpuUsageUsec: _asIntOrNull(map['cpuUsageUsec']),
      networkRxBytes: _asIntOrNull(map['networkRxBytes']),
      networkTxBytes: _asIntOrNull(map['networkTxBytes']),
      blockReadBytes: _asIntOrNull(map['blockReadBytes']),
      blockWriteBytes: _asIntOrNull(map['blockWriteBytes']),
      numProcesses: _asIntOrNull(map['numProcesses']),
    );
  }
}

/// One timestamped sample in the foreground container-stats history.
///
/// Network and disk values are cumulative counters. CPU percent is derived
/// between two samples and is null until two usable CPU counters are available.
class ContainerStatsSample {
  const ContainerStatsSample({
    required this.timestamp,
    this.cpuPercent,
    this.memoryBytes,
    this.networkRxBytes,
    this.networkTxBytes,
    this.diskReadBytes,
    this.diskWriteBytes,
  });

  final DateTime timestamp;
  final double? cpuPercent;
  final int? memoryBytes;
  final int? networkRxBytes;
  final int? networkTxBytes;
  final int? diskReadBytes;
  final int? diskWriteBytes;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((k, v) => MapEntry(k.toString(), v.toString()));
}

int _asInt(Object? value) => _asIntOrNull(value) ?? 0;

int? _asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

DateTime? _asDate(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  return null;
}
