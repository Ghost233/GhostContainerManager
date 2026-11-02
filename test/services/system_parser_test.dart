import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/services/system_parser.dart';
import 'package:ghost_container_manager/services/errors.dart';

void main() {
  test('Docker client/server versions and daemon resource counts', () {
    final versions = parseSystemVersions(
      '{"Client":{"Version":"29.8.2"},"Server":{"Version":"28.1.0"}}',
    );
    expect(versions.cli.toString(), '29.8.2');
    expect(versions.apiServer.toString(), '28.1.0');
    final info = parseSystemStatus(
      '{"Containers":4,"ContainersRunning":2,"Images":5,"DockerRootDir":"/engine/data"}',
    );
    expect(info.running, isTrue);
    expect(info.resources!.containersTotal, 4);
    expect(info.appRoot, '/engine/data');
  });
  test('malformed version and info fail without fabricated status', () {
    expect(() => parseSystemVersions('[]'), throwsFormatException);
    expect(() => parseSystemStatus('[]'), throwsFormatException);
  });
  test('Docker endpoint and permission errors retain original evidence', () {
    expect(
      mapBridgeFailure(
        'Cannot connect to Docker daemon',
        operation: 'inspect',
      ).code,
      GcmErrorCode.runtimeUnavailable,
    );
    expect(
      mapBridgeFailure('permission denied', operation: 'inspect').code,
      GcmErrorCode.permissionDenied,
    );
    expect(
      mapBridgeFailure('timeout', operation: 'inspect', timedOut: true).code,
      GcmErrorCode.timeout,
    );
  });
}
