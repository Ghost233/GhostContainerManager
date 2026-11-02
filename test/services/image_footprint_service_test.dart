import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/services/image_footprint_service.dart';

void main() {
  test('engine image size and writable layer are queried without host filesystem assumptions', () async {
    final bridge = FakeContainerBridge()
      ..imageInspectResponses['sha256:abc'] = {'sizeBytes': 1000}
      ..cliRunResult = const BridgeCommandResult(
        exitCode: 0,
        stdout: '[{"SizeRw":23}]',
        stderr: '',
      );
    final service = ImageFootprintService(bridge: bridge);
    final result = await service.footprintFor(
      digest: 'sha256:abc',
      containerIds: ['web'],
      appRoot: '/remote/engine',
    );
    expect(result.expandedBytes, 1000);
    expect(result.containerDiskBytes, 23);
    expect(bridge.cliRunRequests.single['arguments'], [
      'container',
      'inspect',
      '--size',
      'web',
    ]);
  });
  test('missing writable size is unavailable rather than zero', () async {
    final bridge = FakeContainerBridge()
      ..cliRunResult = const BridgeCommandResult(
        exitCode: 0,
        stdout: '[{}]',
        stderr: '',
      );
    await expectLater(
      ImageFootprintService(bridge: bridge).containerDirectoryBytes('web'),
      throwsException,
    );
  });
}
