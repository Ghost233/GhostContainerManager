import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';

void main() {
  test(
    'bridge exec timeout preserves timeout code and residual-process hint',
    () async {
      final bridge = FakeContainerBridge();
      bridge.containers = [
        <String, Object?>{
          'configuration': <String, Object?>{
            'id': 'web',
            'image': <String, Object?>{
              'reference': 'docker.io/library/nginx:latest',
            },
            'labels': <String, Object?>{},
          },
          'status': 'running',
          'networks': <Object?>[],
        },
      ];
      bridge.execResult = const BridgeExecResult(
        exitCode: 124,
        stdout: 'partial output',
        stderr: '',
        timedOut: true,
      );
      final service = ContainerService(bridge: bridge);
      addTearDown(() async {
        service.stopPolling();
        await service.dispose();
      });

      await expectLater(
        service.exec('web', command: const ['sleep', '30'], timeoutSeconds: 1),
        throwsA(
          isA<GcmException>()
              .having((error) => error.code, 'code', GcmErrorCode.timeout)
              .having((error) => error.message, 'message', contains('1 second'))
              .having(
                (error) => error.hint,
                'hint',
                'The process may still be running inside the container.',
              )
              .having((error) => error.source, 'source', 'xpc'),
        ),
      );
    },
  );
}
