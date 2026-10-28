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
      expect(json['versionSupported'], isTrue);
      expect((json['resources'] as Map)['containersRunning'], 1);
    });
  });

  group('start', () {
    test('恢复默认后旧目录仍在运行时报告冲突', () async {
      bridge.defaultAppRootPath = '/default/root';
      await service.setAppRoot('/app/root');
      await service.setAppRoot(null);

      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
      expect(
        bridge.calls.where((call) => call.startsWith('systemStart')),
        isEmpty,
      );
    });

    test('默认启动后实际目录不同于默认目录时不报告成功', () async {
      bridge.defaultAppRootPath = '/default/root';
      bridge.statusResult = okJson('{"status":"stopped"}');
      bridge.pingScript = [
        const BridgePingResult.ok(
          apiServerVersion: '1.6.0',
          appRoot: '/other/root',
        ),
      ];
      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
      expect(bridge.calls, contains('systemStart installKernel=false'));
    });

    test('服务已在目标目录运行时确认状态而不再次启动', () async {
      await service.setAppRoot('/app/root');
      bridge.pingScript = [
        const BridgePingResult.ok(
          apiServerVersion: '1.6.0',
          appRoot: 'file:///app/root/',
        ),
      ];
      final result = await service.start(installKernel: false);
      expect(result.status, 'running');
      expect(
        bridge.calls.where((call) => call.startsWith('systemStart')),
        isEmpty,
      );
    });

    test('已保存的目录设置无法读取时拒绝启动', () async {
      bridge.appRootReadError = '无法读取运行时数据目录设置';
      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.message,
            'message',
            contains('无法读取'),
          ),
        ),
      );
      expect(
        bridge.calls.where((call) => call.startsWith('systemStart')),
        isEmpty,
      );
    });

    test('内核检测使用保存的运行时数据目录', () async {
      await service.setAppRoot('/Volumes/data/container');
      bridge.kernelPresent = false;
      bridge.kernelsByAppRoot['/Volumes/data/container'] = true;

      expect(await service.kernelInstalledForStart(), isTrue);
    });

    test('外置卷身份无法确认时拒绝启动且不回退默认目录', () async {
      await service.setAppRoot('/Volumes/data/container');
      bridge.appRootValidationError = '外置卷未挂载或身份不匹配';
      bridge.statusResult = okJson('{"status":"stopped"}');

      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.message,
            'message',
            contains('外置卷'),
          ),
        ),
      );
      expect(
        bridge.calls.where((call) => call.startsWith('systemStart')),
        isEmpty,
      );
    });

    test('启动使用保存的目录并核对运行时报告的路径', () async {
      await service.setAppRoot('/Volumes/data/container');
      bridge.statusResult = okJson('{"status":"stopped"}');
      bridge.pingScript = [
        const BridgePingResult.ok(
          apiServerVersion: '1.6.0',
          appRoot: 'file:///Volumes/data/container/',
        ),
      ];

      final result = await service.start(installKernel: false);

      expect(result.status, 'running');
      expect(
        bridge.calls,
        contains(
          'systemStart installKernel=false appRoot=/Volumes/data/container',
        ),
      );
    });

    test('启动后无法确认实际目录时不报告成功', () async {
      await service.setAppRoot('/Volumes/data/container');
      bridge.statusResult = okJson('{"status":"stopped"}');
      bridge.pingScript = [
        const BridgePingResult.ok(apiServerVersion: '1.6.0'),
      ];
      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
    });

    test('启动后实际目录不同于设置时不报告成功', () async {
      await service.setAppRoot('/Volumes/data/container');
      bridge.statusResult = okJson('{"status":"stopped"}');
      bridge.pingScript = [
        const BridgePingResult.ok(
          apiServerVersion: '1.6.0',
          appRoot: '/other/root',
        ),
      ];
      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
    });

    test('已运行服务的数据目录与设置不一致时报告冲突且不停止服务', () async {
      await service.setAppRoot('/new/runtime');

      await expectLater(
        service.start(installKernel: false),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
      expect(bridge.calls, isNot(contains('systemStop')));
    });

    test('成功：CLI 后轮询 ping 并就绪', () async {
      final r = await service.start(installKernel: true);
      expect(bridge.calls, contains('systemStart installKernel=true'));
      expect(bridge.calls, contains('ping'));
      expect(r.readiness.level, ReadinessLevel.ready);
      expect(r.status, 'running');
      expect(r.kernelInstalled, isTrue);
      expect(r.startupMs, greaterThanOrEqualTo(0));
    });

    test('installKernel=false 时启动后不额外探测内核（kernelInstalled 缺省）', () async {
      final r = await service.start(installKernel: false);
      expect(r.kernelInstalled, isNull);
      expect(r.toJson().containsKey('kernelInstalled'), isFalse);
      // 只有一次 kernelInstalled 探测——来自收尾 checkReadiness 的五级
      // 状态机；installKernel=true 时会有两次（多一次启动后探测）。
      expect(bridge.calls.where((c) => c == 'kernelInstalled').length, 1);
      expect(bridge.calls, contains('systemStart installKernel=false'));
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
    test('成功：返回 stopped 与运行中容器计数', () async {
      bridge.containers = <Map<String, Object?>>[
        <String, Object?>{'status': 'running'},
        <String, Object?>{'status': 'stopped'},
        <String, Object?>{'status': 'running'},
      ];
      final r = await service.stop();
      expect(bridge.calls, contains('systemStop'));
      expect(r.status, 'stopped');
      expect(r.containersStopped, 2);
      expect(r.toJson(), <String, Object?>{
        'status': 'stopped',
        'containersStopped': 2,
      });
    });

    test('容器列表不可达时计数为 0，停止照常进行', () async {
      bridge.containerListThrows = true;
      final r = await service.stop();
      expect(r.containersStopped, 0);
      expect(bridge.calls, contains('systemStop'));
    });

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
