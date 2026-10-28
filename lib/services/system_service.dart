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

import 'dart:io';

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

  /// True when the detected runtime satisfies the version gates
  /// (≥ anchor, supported major). False when unknown (notInstalled) or
  /// gated; a debug bypass leaves this true while `debugBypassUsed` marks
  /// the skip.
  bool get versionSupported => switch (level) {
    ReadinessLevel.notInstalled ||
    ReadinessLevel.versionTooLow ||
    ReadinessLevel.unsupportedMajor => false,
    _ => true,
  };

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
/// `kernelInstalled?` and `startupMs`.
class SystemStartResult {
  const SystemStartResult({
    required this.readiness,
    required this.status,
    this.kernelInstalled,
    required this.startupMs,
  });

  final ReadinessResult readiness;

  /// Daemon state after start (`running` — start only returns on a
  /// successful health-check poll).
  final String status;

  /// Post-start kernel presence; only probed (and emitted) when the start
  /// requested kernel installation.
  final bool? kernelInstalled;

  /// Wall-clock time from CLI invocation to the apiserver answering.
  final int startupMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    if (kernelInstalled != null) 'kernelInstalled': kernelInstalled,
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

  Future<String?> getAppRoot() async {
    try {
      return await _bridge.getAppRoot();
    } on BridgeCallException catch (e) {
      throw GcmException(GcmErrorCode.runtimeUnavailable, e.message);
    }
  }

  Future<void> setAppRoot(String? path) async {
    try {
      await _bridge.setAppRoot(path);
    } on BridgeCallException catch (e) {
      throw GcmException(GcmErrorCode.invalidArgument, e.message);
    }
  }

  Future<bool> kernelInstalledForStart() async {
    final root = await getAppRoot();
    if (root != null) {
      try {
        await _bridge.validateAppRoot(root);
      } on BridgeCallException catch (e) {
        throw GcmException(GcmErrorCode.runtimeUnavailable, e.message);
      }
    }
    return _bridge.kernelInstalled(appRoot: root);
  }

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
          source: 'cli',
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
    if (!await _bridge.kernelInstalled(
      appRoot: _tryParseStatus(statusResult.stdout)?.appRoot,
    )) {
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
  Future<SystemStartResult> start({required bool installKernel}) async {
    final appRoot = await getAppRoot();
    var alreadyRunning = false;
    if (appRoot != null) {
      try {
        await _bridge.validateAppRoot(appRoot);
      } on BridgeCallException catch (e) {
        throw GcmException(GcmErrorCode.runtimeUnavailable, e.message);
      }
      final status = await _bridge.systemStatus();
      final current = status.ok ? _tryParseStatus(status.stdout) : null;
      if (current?.running == true &&
          !await _sameAppRoot(appRoot, current?.appRoot)) {
        throw const GcmException(
          GcmErrorCode.conflict,
          '运行中的服务使用了其他数据目录，请手动停止服务后重试',
        );
      }
      alreadyRunning = current?.running == true;
    }
    final stopwatch = Stopwatch()..start();
    if (!alreadyRunning || installKernel) {
      final result = await _bridge.systemStart(
        installKernel: installKernel,
        appRoot: appRoot,
      );
      if (!result.ok) {
        throw mapBridgeFailure(
          result.combinedOutput,
          operation: 'system start',
          timedOut: result.timedOut,
          source: 'cli',
        );
      }
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
        source: 'xpc',
      );
    }
    if (appRoot != null && !await _sameAppRoot(appRoot, ping.appRoot)) {
      throw const GcmException(
        GcmErrorCode.conflict,
        '无法确认运行时使用了设置的数据目录，请检查服务状态',
      );
    }
    stopwatch.stop();
    // Post-start kernel presence is only meaningful when the caller asked
    // for installation; otherwise leave it out of the wire contract.
    final kernelInstalled = installKernel
        ? await _bridge.kernelInstalled(appRoot: ping.appRoot ?? appRoot)
        : null;
    return SystemStartResult(
      readiness: await checkReadiness(),
      status: 'running',
      kernelInstalled: kernelInstalled,
      startupMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// Stops the runtime (`container system stop`). Counts running containers
  /// beforehand (best-effort) so callers can report the blast radius.
  Future<SystemStopResult> stop() async {
    final containersStopped = await _runningContainerCount();
    final result = await _bridge.systemStop();
    if (!result.ok) {
      throw mapBridgeFailure(
        result.combinedOutput,
        operation: 'system stop',
        timedOut: result.timedOut,
        source: 'cli',
      );
    }
    return SystemStopResult(
      status: 'stopped',
      containersStopped: containersStopped,
    );
  }

  /// Running-container count via XPC; 0 when the daemon is unreachable or
  /// the payload is unexpected — stop proceeds regardless.
  Future<int> _runningContainerCount() async {
    try {
      final snapshots = await _bridge.containerList();
      return snapshots.where((s) => s['status'] == 'running').length;
    } catch (_) {
      return 0;
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
        source: 'cli',
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

  Future<bool> _sameAppRoot(String expected, String? actual) async {
    if (actual == null || actual.isEmpty) return false;
    Future<String> normalize(String value) async {
      final uri = Uri.tryParse(value);
      final path = uri?.scheme == 'file' ? uri!.toFilePath() : value;
      final normalized = Uri.file(path).normalizePath().toFilePath();
      try {
        return await Directory(normalized).resolveSymbolicLinks();
      } on FileSystemException {
        return normalized.replaceFirst(RegExp(r'/+$'), '');
      }
    }

    return await normalize(expected) == await normalize(actual);
  }
}
