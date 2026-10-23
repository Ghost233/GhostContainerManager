/// Pure parsers/validators for Apple container CLI JSON output.
///
/// Parses `container system version/status --format json` payloads into
/// typed data. Throws [FormatException] on malformed input; callers (the
/// Service layer) wrap it into `GcmException`. Kept pure so tests can feed
/// real captured payloads.
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

/// Versions reported by `container system version --format json`
/// (a JSON array of {appName, version, ...} entries).
class RuntimeVersions {
  const RuntimeVersions({required this.cli, this.apiServer});

  /// Version of the `container` CLI itself.
  final RuntimeVersion cli;

  /// Version of `container-apiserver`; null when the CLI did not report it
  /// (very old versions) — treated as a skew signal by the caller.
  final RuntimeVersion? apiServer;

  /// CLI and apiserver report different versions; remediation is
  /// `container system restart` (or stop+start).
  bool get skewed =>
      apiServer != null && apiServer.toString() != cli.toString();
}

/// Parses `container system version --format json`.
RuntimeVersions parseSystemVersions(String stdout) {
  final Object? decoded;
  try {
    decoded = jsonDecode(stdout);
  } on FormatException catch (e) {
    throw FormatException('system version output is not JSON: ${e.message}');
  }
  if (decoded is! List) {
    throw const FormatException('system version output is not a JSON array');
  }
  String? cli;
  String? api;
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final name = entry['appName'];
    final version = entry['version'];
    if (name is! String || version is! String) continue;
    if (name == 'container') cli = version;
    if (name == 'container-apiserver') api = version;
  }
  if (cli == null) {
    throw const FormatException(
      'system version output has no "container" entry',
    );
  }
  return RuntimeVersions(
    cli: RuntimeVersion.parse(cli),
    apiServer: api == null ? null : RuntimeVersion.parse(api),
  );
}

/// Resource counters from `container system status --format json`.
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

/// Parsed `container system status --format json` payload.
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

/// Parses `container system status --format json`.
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
  final paths = decoded['paths'];
  final resources = decoded['resources'];
  return SystemStatusData(
    status: decoded['status'] is String ? decoded['status'] as String : '',
    appRoot: paths is Map ? paths['appRoot'] as String? : null,
    installRoot: paths is Map ? paths['installRoot'] as String? : null,
    resources: resources is Map
        ? SystemResources(
            containersRunning:
                (resources['containersRunning'] as num?)?.toInt() ?? 0,
            containersTotal:
                (resources['containersTotal'] as num?)?.toInt() ?? 0,
            images: (resources['images'] as num?)?.toInt() ?? 0,
          )
        : null,
  );
}

/// Maps raw bridge failure text to a structured [GcmException].
///
/// Feature fingerprints (same approach as orchard):
/// - "connection invalid"            → apiserver not reachable
/// - "failed to decode" + "health check" → XPC wire-format mismatch
GcmException mapBridgeFailure(
  String combinedOutput, {
  required String operation,
  bool timedOut = false,
}) {
  if (timedOut) {
    return GcmException(
      GcmErrorCode.timeout,
      '$operation 超时',
      hint: '运行时可能卡住；重试或 container system restart',
      cause: combinedOutput,
    );
  }
  final text = combinedOutput.toLowerCase();
  if (text.contains('connection invalid')) {
    return GcmException(
      GcmErrorCode.runtimeUnavailable,
      'container apiserver 不可达',
      hint: '先执行 container system start',
      cause: combinedOutput,
    );
  }
  if (text.contains('failed to decode') && text.contains('health check')) {
    return GcmException(
      GcmErrorCode.versionMismatch,
      '客户端与 apiserver 版本不兼容',
      hint: 'container system restart；仍失败则对齐 CLI 与 app 内置客户端版本',
      cause: combinedOutput,
    );
  }
  if (text.contains('failed to read user input')) {
    // system start without an explicit kernel-install flag blocks on
    // readLine; the bridge must always pass one — reaching here is a bug.
    return GcmException(
      GcmErrorCode.internal,
      '$operation 卡在交互式输入（kernel-install 标志缺失）',
      hint: '这是 app 缺陷：system start 必须显式传 --enable/--disable-kernel-install',
      cause: combinedOutput,
    );
  }
  if (text.contains('permission denied') || text.contains('not privileged')) {
    return GcmException(
      GcmErrorCode.permissionDenied,
      '$operation 权限不足',
      cause: combinedOutput,
    );
  }
  return GcmException(
    GcmErrorCode.internal,
    '$operation 失败',
    cause: combinedOutput.trim().isEmpty ? null : combinedOutput,
  );
}
