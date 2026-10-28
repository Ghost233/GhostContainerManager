/// UI-side state holder for runtime readiness and system actions.
///
/// Wraps [SystemService] (the single authority, see docs/spec/onboarding.md)
/// and exposes ChangeNotifier state for the onboarding flow, the runtime
/// page and the degraded-shell banner. All validation/parsing stays in the
/// Service layer; this controller only sequences calls and carries
/// presentation state (busy flags, last error).
library;

// 公共命名参数名（systemService、bridge）需保持与私有字段解耦的可见名，
// 与 T1a 服务侧一致关闭该 lint。
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../bridge/container_bridge.dart';
import '../../services/errors.dart';
import '../../services/system_parser.dart';
import '../../services/system_service.dart';

/// Which long-running action, if any, is in flight.
enum SystemAction { none, checking, starting, stopping, installingKernel }

class ReadinessController extends ChangeNotifier {
  ReadinessController({
    required SystemService systemService,
    required ContainerBridge bridge,
  }) : _systemService = systemService;

  final SystemService _systemService;

  /// Latest readiness evaluation; null before the first check completes.
  ReadinessResult? readiness;

  /// Latest daemon status payload (running flag, resources); may lag
  /// [readiness] by one refresh and is null when the daemon never answered.
  SystemStatusData? statusData;

  /// Saved directory for the next start, or null for the runtime default.
  String? savedAppRoot;
  bool appRootLoaded = false;

  SystemAction action = SystemAction.none;

  /// Last action/check failure, cleared on the next attempt.
  GcmException? lastError;

  bool get busy => action != SystemAction.none;

  /// True while a version gate was skipped via
  /// GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME (debug builds only).
  bool get debugBypassUsed => readiness?.debugBypassUsed ?? false;

  /// Full re-check: readiness state machine + daemon status.
  Future<void> refresh() => _run(SystemAction.checking, () async {
    final info = await _systemService.status();
    readiness = info.readiness;
    statusData = info.statusData;
    appRootLoaded = false;
    savedAppRoot = await _systemService.getAppRoot();
    appRootLoaded = true;
  });

  Future<void> setAppRoot(String? path) =>
      _run(SystemAction.checking, () async {
        await _systemService.setAppRoot(path);
        savedAppRoot = await _systemService.getAppRoot();
        appRootLoaded = true;
      });

  /// One-click runtime start. The mandatory kernel-install flag is chosen
  /// from the kernel probe: missing kernel → --enable-kernel-install
  /// (installs it in the same pass, onboarding.md Q3), present →
  /// --disable-kernel-install.
  Future<void> startRuntime() => _run(SystemAction.starting, () async {
    final kernelPresent = await _systemService.kernelInstalledForStart();
    final result = await _systemService.start(installKernel: !kernelPresent);
    readiness = result.readiness;
    await _refreshStatusOnly();
  });

  /// Stops the runtime (`container system stop`). The caller is responsible
  /// for the confirmation dialog (issue #16 / ui-ia.md D8).
  Future<void> stopRuntime() => _run(SystemAction.stopping, () async {
    await _systemService.stop();
    await _refreshStatusOnly();
    readiness = await _systemService.checkReadiness();
  });

  /// One-click recommended-kernel install (kernelMissing 引导动作).
  Future<void> installKernel() => _run(SystemAction.installingKernel, () async {
    await _systemService.installKernel();
    readiness = await _systemService.checkReadiness();
    await _refreshStatusOnly();
  });

  Future<void> _refreshStatusOnly() async {
    final info = await _systemService.status();
    statusData = info.statusData;
  }

  Future<void> _run(SystemAction a, Future<void> Function() body) async {
    if (busy) return; // 执行中阻止重复提交（macos-ui-standards 控件状态）
    action = a;
    lastError = null;
    notifyListeners();
    try {
      await body();
    } on GcmException catch (e) {
      lastError = e;
    } catch (e) {
      // Non-service exceptions (e.g. bridge channel drops mid-flight) must
      // still surface as an actionable error instead of dying silently.
      lastError = GcmException(GcmErrorCode.internal, '未预期的错误', cause: e);
    } finally {
      action = SystemAction.none;
      notifyListeners();
    }
  }
}
