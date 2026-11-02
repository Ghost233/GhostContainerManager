import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:ghost_container_manager/services/errors.dart';

void main() {
  test(
    'Docker readiness accepts independent client and server versions',
    () async {
      final bridge = FakeContainerBridge();
      final service = SystemService(bridge: bridge);
      expect((await service.checkReadiness()).ready, isTrue);
      expect(
        bridge.calls,
        containsAll(['locateBinary', 'systemVersion', 'systemStatus']),
      );
      expect(bridge.calls.where((c) => c.contains('kernel')), isEmpty);
    },
  );
  test(
    'missing CLI and disconnected endpoints remain separate failures',
    () async {
      final bridge = FakeContainerBridge()..binaryPath = null;
      final service = SystemService(bridge: bridge);
      expect(
        (await service.checkReadiness()).level,
        ReadinessLevel.notInstalled,
      );
      bridge.binaryPath = '/bin/docker';
      bridge.statusResult = const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to Docker daemon',
      );
      expect(
        (await service.checkReadiness()).level,
        ReadinessLevel.serviceNotRunning,
      );
      await expectLater(service.start(), throwsA(isA<GcmException>()));
    },
  );
  test(
    'engine lifecycle and host data directory are not controlled implicitly',
    () async {
      final bridge = FakeContainerBridge();
      final service = SystemService(bridge: bridge);
      expect((await service.start()).status, 'running');
      await expectLater(service.stop(), throwsA(isA<GcmException>()));
      await expectLater(
        service.setAppRoot('/host/path'),
        throwsA(isA<GcmException>()),
      );
      expect(
        bridge.calls.where(
          (c) => c.startsWith('systemStop') || c.startsWith('systemStart'),
        ),
        isEmpty,
      );
    },
  );
}
