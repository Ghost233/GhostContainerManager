/// Read-only mount aggregation across containers (T6, docs/spec/mcp-tools.md
/// §3.4, ui-ia.md D7).
///
/// Reality check (verified against CLI 1.5.0 output): Apple container has no
/// first-class volume resource — mounts live in each container's
/// configuration. A "mount" here is therefore an *aggregated view* keyed by
/// host source path, listing every container that references it. tmpfs
/// mounts have no host source and are keyed `tmpfs:<destination>`.
library;

// ignore_for_file: prefer_initializing_formals

import 'container_service.dart';
import 'errors.dart';

/// One container's use of a mount source.
class MountUsage {
  const MountUsage({
    required this.containerId,
    required this.destination,
    required this.readOnly,
  });

  final String containerId;

  /// Path inside the container.
  final String destination;

  final bool readOnly;
}

/// Aggregated mount source (host path → all referencing containers).
class MountInfo {
  const MountInfo({
    required this.name,
    required this.type,
    this.source,
    required this.usedBy,
  });

  /// Stable identifier: host source path, or `tmpfs:<destination>`.
  final String name;

  /// `virtiofs` or `tmpfs` (wire format: `type` is a single-key map).
  final String type;

  /// Host path; null for tmpfs mounts.
  final String? source;

  final List<MountUsage> usedBy;

  /// True when every referencing container mounts this source read-only.
  bool get fullyReadOnly => usedBy.every((usage) => usage.readOnly);

  Map<String, Object?> toWire() => <String, Object?>{
    'name': name,
    'type': type,
    if (source != null) 'source': source,
    'readOnly': fullyReadOnly,
    'usedBy': usedBy
        .map(
          (usage) => <String, Object?>{
            'containerId': usage.containerId,
            'destination': usage.destination,
            'readOnly': usage.readOnly,
          },
        )
        .toList(growable: false),
  };
}

/// Aggregates container mounts into per-source views. Purely read-only —
/// mount creation/removal is container-config territory and out of v1 scope.
///
/// Mount reads cover every container regardless of state (default
/// [ContainerQuery] includes stopped containers).
class MountService {
  MountService({required ContainerService containerService})
    : _containerService = containerService;

  final ContainerService _containerService;

  /// All mounts aggregated by source, including stopped containers (mount
  /// config exists independently of run state).
  Future<List<MountInfo>> listMounts() async {
    final containers = await _containerService.listContainers(
      const ContainerQuery(),
    );
    final byName = <String, _MutableMount>{};
    for (final container in containers) {
      for (final parsed in _parseMounts(container.rawConfiguration['mounts'])) {
        final name = parsed.name;
        byName
            .putIfAbsent(
              name,
              () => _MutableMount(
                name: name,
                type: parsed.type,
                source: parsed.source,
              ),
            )
            .usedBy
            .add(
              MountUsage(
                containerId: container.id,
                destination: parsed.destination,
                readOnly: parsed.readOnly,
              ),
            );
      }
    }
    return byName.values
        .map(
          (entry) => MountInfo(
            name: entry.name,
            type: entry.type,
            source: entry.source,
            usedBy: List.unmodifiable(entry.usedBy),
          ),
        )
        .toList(growable: false);
  }

  /// Detail for one mount [name] (host source path or `tmpfs:<destination>`).
  Future<MountInfo> inspectMount(String name) async {
    final mounts = await listMounts();
    for (final mount in mounts) {
      if (mount.name == name) return mount;
    }
    throw GcmException(
      GcmErrorCode.notFound,
      'Mount "$name" was not found.',
      hint:
          'Mount names are host source paths (or tmpfs:<destination>); '
          'list mounts first to get exact names.',
    );
  }

  /// Parses the wire format (locked against CLI 1.5.0):
  /// `{"destination", "options": ["ro"], "source", "type": {"virtiofs": {}}}`
  static List<_ParsedMount> _parseMounts(Object? value) {
    if (value is! List) return const [];
    final result = <_ParsedMount>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      final destination = map['destination'];
      if (destination is! String) continue;
      final typeMap = map['type'];
      final type = typeMap is Map && typeMap.isNotEmpty
          ? typeMap.keys.first as String
          : 'virtiofs';
      final source = map['source'] as String?;
      final options = map['options'];
      final readOnly = options is List && options.contains('ro');
      result.add(
        _ParsedMount(
          name: source ?? 'tmpfs:$destination',
          type: type,
          source: source,
          destination: destination,
          readOnly: readOnly,
        ),
      );
    }
    return result;
  }
}

class _ParsedMount {
  const _ParsedMount({
    required this.name,
    required this.type,
    required this.source,
    required this.destination,
    required this.readOnly,
  });

  final String name;
  final String type;
  final String? source;
  final String destination;
  final bool readOnly;
}

class _MutableMount {
  _MutableMount({required this.name, required this.type, required this.source});

  final String name;
  final String type;
  final String? source;
  final List<MountUsage> usedBy = <MountUsage>[];
}
