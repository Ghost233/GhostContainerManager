import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/system_service.dart';

BridgeCommandResult okJson(String stdout) =>
    BridgeCommandResult(exitCode: 0, stdout: stdout, stderr: '');

BridgeCommandResult fail(String stderr, {int exitCode = 1}) =>
    BridgeCommandResult(exitCode: exitCode, stdout: '', stderr: stderr);

String versionJson(String cli, [String? api]) =>
    '[{"appName":"container","version":"$cli"}'
    '${api != null ? ',{"appName":"container-apiserver","version":"$api"}' : ''}]';

void main() {
  late FakeContainerBridge bridge;
  late SystemService service;

  SystemService build({bool bypass = false}) => SystemService(
    bridge: bridge,
    debugBypassEnabled: bypass,
    pingInterval: Duration.zero,
  );

  setUp(() {
    bridge = FakeContainerBridge();
    service = build();
  });

  group('checkReadiness 五级短路', () {
    test('notInstalled 短路：不触碰 version/status', () async {
      bridge.binaryPath = null;
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.notInstalled);
      expect(r.ready, isFalse);
      expect(bridge.calls, ['locateBinary']);
    });

    test('versionTooLow（1.5.0 < 1.6.0）', () async {
      bridge.versionResult = okJson(versionJson('1.5.0', '1.5.0'));
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.versionTooLow);
      expect(r.cliVersion.toString(), '1.5.0');
      expect(r.detail, contains('1.6.0'));
      // 短路：未查 status/kernel
      expect(bridge.calls, isNot(contains('systemStatus')));
    });

    test('unsupportedMajor（2.x，大版本锁 1）', () async {
      bridge.versionResult = okJson(versionJson('2.0.0'));
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.unsupportedMajor);
    });

    test('debug 绕行跳过版本门但不跳过 notInstalled', () async {
      bridge.versionResult = okJson(versionJson('1.5.0', '1.5.0'));
      service = build(bypass: true);
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.ready);
      expect(r.debugBypassUsed, isTrue);

      bridge.binaryPath = null;
      final r2 = await service.checkReadiness();
      expect(r2.level, ReadinessLevel.notInstalled);
    });

    test('serviceNotRunning：status exit!=0', () async {
      bridge.statusResult = fail('launchd service not registered');
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.serviceNotRunning);
    });

    test('serviceNotRunning：status 非 running', () async {
      bridge.statusResult = okJson('{"status":"stopped"}');
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.serviceNotRunning);
    });

    test('kernelMissing', () async {
      bridge.kernelPresent = false;
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.kernelMissing);
    });

    test('ready：全部通过', () async {
      final r = await service.checkReadiness();
      expect(r.level, ReadinessLevel.ready);
      expect(r.ready, isTrue);
      expect(r.cliVersion.toString(), '1.6.0');
      expect(r.installPath, '/opt/homebrew/bin/container');
    });

    test('版本双端不一致在 ready 时给出 restart 提示', () async {
      bridge.versionResult = okJson(versionJson('1.6.0', '1.5.9'));
      final r = await service.checkReadiness();
      // 任一端低于基线即 versionTooLow
      expect(r.level, ReadinessLevel.versionTooLow);

      bridge.versionResult = okJson(versionJson('1.6.1', '1.6.0'));
      final r2 = await service.checkReadiness();
      expect(r2.level, ReadinessLevel.ready);
      expect(r2.detail, contains('restart'));
    });

    test('customBinaryPath 优先', () async {
      bridge.binaryPath = null;
      final r = await service.checkReadiness(
        customBinaryPath: '/custom/container',
      );
      expect(r.level, isNot(ReadinessLevel.notInstalled));
      expect(bridge.calls.first, contains('/custom/container'));
    });

    test('version CLI 失败映射为结构化错误', () async {
      bridge.versionResult = fail('connection invalid');
      await expectLater(
        service.checkReadiness(),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.runtimeUnavailable,
          ),
        ),
      );
    });

    test('version 输出畸形 → INTERNAL', () async {
      bridge.versionResult = okJson('garbage');
      await expectLater(
        service.checkReadiness(),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.internal,
          ),
        ),
      );
    });
  });

  group('status', () {
    test('聚合就绪级别与资源计数', () async {
      final info = await service.status();
      expect(info.readiness.level, ReadinessLevel.ready);
      expect(info.statusData!.running, isTrue);
      expect(info.statusData!.resources!.images, 3);
      final json = info.toJson();
      expect(json['level'], 'ready');
      expect((json['resources'] as Map)['containersRunning'], 1);
    });
  });

  group('start', () {
    test('成功：CLI 后轮询 ping 并就绪', () async {
      final r = await service.start(installKernel: true);
      expect(bridge.calls, contains('systemStart installKernel=true'));
      expect(bridge.calls, contains('ping'));
      expect(r.level, ReadinessLevel.ready);
    });

    test('CLI 失败映射错误', () async {
      bridge.startResult = fail('boom');
      await expectLater(
        service.start(installKernel: false),
        throwsA(isA<GcmException>()),
      );
    });

    test('ping 持续失败 → 映射为 RUNTIME_UNAVAILABLE', () async {
      bridge.pingScript = [
        const BridgePingResult.failure('connection invalid'),
      ];
      service = SystemService(
        bridge: bridge,
        pingAttempts: 3,
        pingInterval: Duration.zero,
      );
      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.runtimeUnavailable,
          ),
        ),
      );
      expect(bridge.calls.where((c) => c == 'ping').length, 3);
    });
  });

  group('stop', () {
    test('失败映射：health check 解码错误 → VERSION_MISMATCH', () async {
      bridge.stopResult = fail(
        'failed to decode apiServerVersion in health check',
      );
      await expectLater(
        service.stop(),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.versionMismatch,
          ),
        ),
      );
    });
  });

  group('installKernel', () {
    test('already exists 时以 --force 重试一次', () async {
      var forceCalls = 0;
      final custom = _KernelRetryBridge(onForce: () => forceCalls++);
      service = SystemService(bridge: custom, pingInterval: Duration.zero);
      await service.installKernel();
      expect(forceCalls, 1);
    });
  });
}

/// Bridge whose first kernel set fails with "already exists".
class _KernelRetryBridge extends FakeContainerBridge {
  _KernelRetryBridge({required this.onForce});

  final void Function() onForce;
  var _first = true;

  @override
  Future<BridgeCommandResult> kernelSetRecommended({bool force = false}) {
    if (_first) {
      _first = false;
      return Future.value(fail('kernel already exists'));
    }
    expect(force, isTrue);
    onForce();
    return Future.value(okJson(''));
  }
}
