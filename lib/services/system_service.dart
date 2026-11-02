library;

// The public named parameters (bridge, ...) must keep
// their public names, so the initializing-formals lint cannot apply here.
// ignore_for_file: prefer_initializing_formals

import 'system_parser.dart';
import '../bridge/container_bridge.dart';
import 'errors.dart';

/// Readiness levels in check order.
enum ReadinessLevel { notInstalled, serviceNotRunning, ready }

/// Outcome of one readiness evaluation.
class ReadinessResult {
  const ReadinessResult({
    required this.level,
    this.cliVersion,
    this.apiServerVersion,
    this.installPath,
    this.detail,
  });

  final ReadinessLevel level;
  final RuntimeVersion? cliVersion;
  final RuntimeVersion? apiServerVersion;

  /// Located Docker CLI binary path (null when not installed).
  final String? installPath;

  /// Human-readable detail for the current level (e.g. required version,
  /// version-skew remediation).
  final String? detail;

  bool get ready => level == ReadinessLevel.ready;

  /// Compatibility field: the Docker CLI is present.
  bool get versionSupported => level != ReadinessLevel.notInstalled;

  Map<String, Object?> toJson() => <String, Object?>{
    'level': level.name,
    'ready': ready,
    if (cliVersion != null) 'cliVersion': cliVersion.toString(),
    if (apiServerVersion != null)
      'apiServerVersion': apiServerVersion.toString(),
    if (installPath != null) 'installPath': installPath,
    if (detail != null) 'detail': detail,
  };
}

/// Aggregated status returned by [SystemService.status] and the
/// `system_status` MCP tool.
class SystemStatusInfo {
  const SystemStatusInfo({required this.readiness, this.statusData});

  final ReadinessResult readiness;

  /// Parsed `system status` payload; present when the daemon answered.
  final SystemStatusData? statusData;

  Map<String, Object?> toJson() => <String, Object?>{
    ...readiness.toJson(),
    'versionSupported': readiness.versionSupported,
    if (statusData != null) ...<String, Object?>{
      'status': statusData!.status,
      if (statusData!.appRoot != null) 'appRoot': statusData!.appRoot,
      if (statusData!.installRoot != null)
        'installRoot': statusData!.installRoot,
      if (statusData!.resources != null)
        'resources': statusData!.resources!.toJson(),
    },
  };
}

/// Result of [SystemService.start] (mcp-tools.md §3.3 `system_start`
/// contract): final readiness plus the wire fields `status`,
/// connection timing and status.
class SystemStartResult {
  const SystemStartResult({
    required this.readiness,
    required this.status,
    required this.startupMs,
  });

  final ReadinessResult readiness;

  /// Daemon state after start (`running` — start only returns on a
  /// successful health-check poll).
  final String status;

  final int startupMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'startupMs': startupMs,
    ...readiness.toJson(),
  };
}

/// Result of [SystemService.stop] (§3.3 `system_stop` contract).
class SystemStopResult {
  const SystemStopResult({
    required this.status,
    required this.containersStopped,
  });

  /// Daemon state after stop (`stopped`).
  final String status;

  /// Running containers the stop takes down with the daemon (best-effort
  /// pre-stop count; 0 when the daemon was already unreachable).
  final int containersStopped;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'containersStopped': containersStopped,
  };
}

/// System-domain service: the single authority for runtime readiness and
/// start/stop. All validation happens here; the bridge stays thin (E02).
class SystemService {
  SystemService({required ContainerBridge bridge}) : _bridge = bridge;
  final ContainerBridge _bridge;
  Future<String?> getAppRoot() async => null;
  Future<void> setAppRoot(String? path) async => throw const GcmException(
    GcmErrorCode.invalidArgument,
    '数据目录由所选 Docker 引擎管理，请在引擎配置中修改。',
  );
  Future<ReadinessResult> checkReadiness({String? customBinaryPath}) async {
    final path = await _bridge.locateBinary(customPath: customBinaryPath);
    if (path == null) {
      return const ReadinessResult(
        level: ReadinessLevel.notInstalled,
        detail: '未找到 Docker CLI，请安装并配置 Docker 兼容端点。',
      );
    }
    final result = await _bridge.systemVersion();
    RuntimeVersions? versions;
    try {
      versions = parseSystemVersions(result.stdout);
    } on FormatException {
      /* Endpoint diagnostics below retain raw errors. */
    }
    final info = await _bridge.systemStatus();
    return ReadinessResult(
      level: info.ok ? ReadinessLevel.ready : ReadinessLevel.serviceNotRunning,
      cliVersion: versions?.cli,
      apiServerVersion: versions?.apiServer,
      installPath: path,
      detail: info.ok
          ? null
          : 'Docker 端点不可达：${info.combinedOutput.trim()}。请检查当前 context、DOCKER_HOST 和引擎状态。',
    );
  }

  Future<SystemStatusInfo> status({String? customBinaryPath}) async {
    final readiness = await checkReadiness(customBinaryPath: customBinaryPath);
    final result = await _bridge.systemStatus();
    SystemStatusData? data;
    if (result.ok) {
      try {
        data = parseSystemStatus(result.stdout);
      } on FormatException catch (e) {
        throw GcmException(GcmErrorCode.internal, '无法解析 Docker info', cause: e);
      }
    }
    return SystemStatusInfo(readiness: readiness, statusData: data);
  }

  Future<SystemStartResult> start() async {
    final readiness = await checkReadiness();
    if (!readiness.ready) {
      throw GcmException(
        GcmErrorCode.runtimeUnavailable,
        '请在外部启动所选引擎并配置 Docker 连接。',
        hint: readiness.detail,
      );
    }
    return SystemStartResult(
      readiness: readiness,
      status: 'running',
      startupMs: 0,
    );
  }

  Future<SystemStopResult> stop() async => throw const GcmException(
    GcmErrorCode.invalidArgument,
    'Docker 兼容接口没有通用的引擎停止命令，请通过引擎自身管理入口停止。',
  );
}
