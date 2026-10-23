/// Five-level short-circuit readiness state machine for the Apple container
/// runtime, plus system start/stop. See docs/spec/onboarding.md and
/// issue #16 acceptance criteria 1/5.
///
/// Levels (checked in order, first failure wins):
///   notInstalled → versionTooLow → unsupportedMajor → serviceNotRunning
///   → kernelMissing → ready
///
/// Debug bypass: `GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME=1` (debug builds only)
/// skips the two version-gate levels so development on older/newer runtimes
/// is possible; it never skips notInstalled.
library;

// The public named parameters (bridge, debugBypassEnabled, ...) must keep
// their public names, so the initializing-formals lint cannot apply here.
// ignore_for_file: prefer_initializing_formals

import 'system_parser.dart';
import '../bridge/container_bridge.dart';
import 'errors.dart';

/// Readiness levels in check order.
enum ReadinessLevel {
  notInstalled,
  versionTooLow,
  unsupportedMajor,
  serviceNotRunning,
  kernelMissing,
  ready,
}

/// Outcome of one readiness evaluation.
class ReadinessResult {
  const ReadinessResult({
    required this.level,
    this.cliVersion,
    this.apiServerVersion,
    this.installPath,
    this.detail,
    this.debugBypassUsed = false,
  });

  final ReadinessLevel level;
  final RuntimeVersion? cliVersion;
  final RuntimeVersion? apiServerVersion;

  /// Located `container` binary path (null when not installed).
  final String? installPath;

  /// Human-readable detail for the current level (e.g. required version,
  /// version-skew remediation).
  final String? detail;

  /// True when a version gate was skipped via the debug bypass.
  final bool debugBypassUsed;

  bool get ready => level == ReadinessLevel.ready;

  Map<String, Object?> toJson() => <String, Object?>{
    'level': level.name,
    'ready': ready,
    if (cliVersion != null) 'cliVersion': cliVersion.toString(),
    if (apiServerVersion != null)
      'apiServerVersion': apiServerVersion.toString(),
    if (installPath != null) 'installPath': installPath,
    if (detail != null) 'detail': detail,
    if (debugBypassUsed) 'debugBypass': true,
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

/// System-domain service: the single authority for runtime readiness and
/// start/stop. All validation happens here; the bridge stays thin (E02).
class SystemService {
  SystemService({
    required ContainerBridge bridge,
    bool debugBypassEnabled = false,
    int pingAttempts = 10,
    Duration pingInterval = const Duration(milliseconds: 500),
  }) : _bridge = bridge,
       _debugBypassEnabled = debugBypassEnabled,
       _pingAttempts = pingAttempts,
       _pingInterval = pingInterval;

  /// Lowest supported runtime version (docs/spec/onboarding.md 锚点).
  static final RuntimeVersion anchorVersion = RuntimeVersion.parse('1.6.0');

  /// Only this major version line is supported.
  static const int supportedMajor = 1;

  final ContainerBridge _bridge;
  final bool _debugBypassEnabled;
  final int _pingAttempts;
  final Duration _pingInterval;

  /// Evaluates the five-level short-circuit state machine.
  Future<ReadinessResult> checkReadiness({String? customBinaryPath}) async {
    // 1. Installed?
    final path = await _bridge.locateBinary(customPath: customBinaryPath);
    if (path == null) {
      return const ReadinessResult(
        level: ReadinessLevel.notInstalled,
        detail: '未找到 container CLI（/usr/local/bin、/opt/homebrew/bin 或自定义路径）',
      );
    }

    // 2/3. Version gates (bypassable in debug).
    var bypassUsed = false;
    RuntimeVersions? versions;
    try {
      final result = await _bridge.systemVersion();
      if (!result.ok) {
        throw mapBridgeFailure(
          result.combinedOutput,
          operation: 'system version',
          timedOut: result.timedOut,
        );
      }
      versions = parseSystemVersions(result.stdout);
    } on FormatException catch (e) {
      throw GcmException(
        GcmErrorCode.internal,
        '无法解析 system version 输出',
        cause: e,
      );
    }

    ReadinessLevel? gateLevel;
    String? gateDetail;
    for (final v in [
      versions.cli,
      if (versions.apiServer != null) versions.apiServer!,
    ]) {
      if (v.major > supportedMajor) {
        gateLevel = ReadinessLevel.unsupportedMajor;
        gateDetail = '运行时大版本 $v 超出支持范围（锁定大版本 $supportedMajor）';
        break;
      }
      if (v < anchorVersion) {
        gateLevel = ReadinessLevel.versionTooLow;
        gateDetail = '运行时版本 $v 低于基线 $anchorVersion';
        break;
      }
    }
    if (gateLevel != null) {
      if (_debugBypassEnabled) {
        bypassUsed = true;
      } else {
        return ReadinessResult(
          level: gateLevel,
          cliVersion: versions.cli,
          apiServerVersion: versions.apiServer,
          installPath: path,
          detail: gateDetail,
        );
      }
    }

    final skewDetail = versions.skewed
        ? 'CLI 与 apiserver 版本不一致，请 container system restart'
        : null;

    // 4. Service running?
    final statusResult = await _bridge.systemStatus();
    final serviceUp =
        statusResult.ok &&
        _tryParseStatus(statusResult.stdout)?.running == true;
    if (!serviceUp) {
      return ReadinessResult(
        level: ReadinessLevel.serviceNotRunning,
        cliVersion: versions.cli,
        apiServerVersion: versions.apiServer,
        installPath: path,
        detail: 'container 服务未运行（system status 未报告 running）',
        debugBypassUsed: bypassUsed,
      );
    }

    // 5. Kernel installed?
    if (!await _bridge.kernelInstalled()) {
      return ReadinessResult(
        level: ReadinessLevel.kernelMissing,
        cliVersion: versions.cli,
        apiServerVersion: versions.apiServer,
        installPath: path,
        detail: '缺少默认内核（default.kernel-arm64），可用 system kernel set 安装',
        debugBypassUsed: bypassUsed,
      );
    }

    return ReadinessResult(
      level: ReadinessLevel.ready,
      cliVersion: versions.cli,
      apiServerVersion: versions.apiServer,
      installPath: path,
      detail: skewDetail,
      debugBypassUsed: bypassUsed,
    );
  }

  /// Readiness + daemon status/resources for UI and `system_status`.
  Future<SystemStatusInfo> status({String? customBinaryPath}) async {
    final readiness = await checkReadiness(customBinaryPath: customBinaryPath);
    SystemStatusData? data;
    final result = await _bridge.systemStatus();
    if (result.ok) {
      data = _tryParseStatus(result.stdout);
    }
    return SystemStatusInfo(readiness: readiness, statusData: data);
  }

  /// Starts the runtime. [installKernel] maps to the mandatory explicit
  /// `--enable/--disable-kernel-install` CLI flag. After the CLI returns,
  /// polls the XPC health check until the apiserver answers.
  Future<ReadinessResult> start({required bool installKernel}) async {
    final result = await _bridge.systemStart(installKernel: installKernel);
    if (!result.ok) {
      throw mapBridgeFailure(
        result.combinedOutput,
        operation: 'system start',
        timedOut: result.timedOut,
      );
    }
    BridgePingResult ping = const BridgePingResult.failure('not polled');
    for (var attempt = 0; attempt < _pingAttempts; attempt++) {
      ping = await _bridge.ping();
      if (ping.ok) break;
      if (attempt + 1 < _pingAttempts) {
        await Future<void>.delayed(_pingInterval);
      }
    }
    if (!ping.ok) {
      throw mapBridgeFailure(
        ping.error ?? 'ping failed',
        operation: 'system start 后健康检查',
      );
    }
    return checkReadiness();
  }

  /// Stops the runtime (`container system stop`).
  Future<void> stop() async {
    final result = await _bridge.systemStop();
    if (!result.ok) {
      throw mapBridgeFailure(
        result.combinedOutput,
        operation: 'system stop',
        timedOut: result.timedOut,
      );
    }
  }

  /// Installs the recommended default kernel; retries once with --force when
  /// the CLI reports the kernel already exists.
  Future<void> installKernel() async {
    var result = await _bridge.kernelSetRecommended();
    if (!result.ok &&
        result.combinedOutput.toLowerCase().contains('already exists')) {
      result = await _bridge.kernelSetRecommended(force: true);
    }
    if (!result.ok) {
      throw mapBridgeFailure(
        result.combinedOutput,
        operation: 'kernel set',
        timedOut: result.timedOut,
      );
    }
  }

  SystemStatusData? _tryParseStatus(String stdout) {
    try {
      return parseSystemStatus(stdout);
    } on FormatException {
      return null;
    }
  }
}
