library;

import 'dart:convert';

import 'errors.dart';

/// Minimal semantic version (major.minor.patch, optional suffix ignored).
class RuntimeVersion implements Comparable<RuntimeVersion> {
  const RuntimeVersion(this.major, this.minor, this.patch);

  factory RuntimeVersion.parse(String raw) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(raw.trim());
    if (match == null) {
      throw FormatException('not a semantic version: "$raw"');
    }
    return RuntimeVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(RuntimeVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(RuntimeVersion o) => compareTo(o) < 0;
  bool operator >=(RuntimeVersion o) => compareTo(o) >= 0;

  @override
  String toString() => '$major.$minor.$patch';
}

class RuntimeVersions {
  const RuntimeVersions({required this.cli, this.apiServer});

  /// Version of the `container` CLI itself.
  final RuntimeVersion cli;

  final RuntimeVersion? apiServer;

  bool get skewed =>
      apiServer != null && apiServer.toString() != cli.toString();
}

RuntimeVersions parseSystemVersions(String stdout) {
  final Object? decoded;
  try {
    decoded = jsonDecode(stdout);
  } on FormatException catch (e) {
    throw FormatException('system version output is not JSON: ${e.message}');
  }
  if (decoded is! Map || decoded['Client'] is! Map) {
    throw const FormatException('Docker version output has no Client object');
  }
  final server = decoded['Server'];
  return RuntimeVersions(
    cli: RuntimeVersion.parse('${decoded['Client']['Version']}'),
    apiServer: server is Map && server['Version'] is String
        ? RuntimeVersion.parse(server['Version'] as String)
        : null,
  );
}

class SystemResources {
  const SystemResources({
    required this.containersRunning,
    required this.containersTotal,
    required this.images,
  });

  final int containersRunning;
  final int containersTotal;
  final int images;

  Map<String, Object?> toJson() => <String, Object?>{
    'containersRunning': containersRunning,
    'containersTotal': containersTotal,
    'images': images,
  };
}

class SystemStatusData {
  const SystemStatusData({
    required this.status,
    this.appRoot,
    this.installRoot,
    this.resources,
  });

  /// Daemon status string, e.g. "running".
  final String status;
  final String? appRoot;
  final String? installRoot;
  final SystemResources? resources;

  bool get running => status == 'running';
}

SystemStatusData parseSystemStatus(String stdout) {
  final Object? decoded;
  try {
    decoded = jsonDecode(stdout);
  } on FormatException catch (e) {
    throw FormatException('system status output is not JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw const FormatException('system status output is not a JSON object');
  }
  return SystemStatusData(
    status: 'running',
    appRoot: decoded['DockerRootDir'] as String?,
    resources: SystemResources(
      containersRunning: (decoded['ContainersRunning'] as num?)?.toInt() ?? 0,
      containersTotal: (decoded['Containers'] as num?)?.toInt() ?? 0,
      images: (decoded['Images'] as num?)?.toInt() ?? 0,
    ),
  );
}

GcmException mapBridgeFailure(
  String combinedOutput, {
  required String operation,
  bool timedOut = false,
  String? source,
}) {
  if (timedOut) {
    return GcmException(
      GcmErrorCode.timeout,
      '$operation 超时',
      hint: '运行时可能卡住；检查 Docker 端点和引擎状态后重试',
      source: source,
      cause: combinedOutput,
    );
  }
  final text = combinedOutput.toLowerCase();
  if (text.contains('cannot connect') ||
      text.contains('connection refused') ||
      text.contains('is the docker daemon running')) {
    return GcmException(
      GcmErrorCode.runtimeUnavailable,
      'Docker 端点不可达',
      hint: '检查 Docker context、DOCKER_HOST 和引擎状态',
      source: source,
      cause: combinedOutput,
    );
  }
  if (text.contains('permission denied') || text.contains('not privileged')) {
    return GcmException(
      GcmErrorCode.permissionDenied,
      '$operation 权限不足',
      source: source,
      cause: combinedOutput,
    );
  }
  return GcmException(
    GcmErrorCode.internal,
    '$operation 失败',
    source: source,
    cause: combinedOutput.trim().isEmpty ? null : combinedOutput,
  );
}
