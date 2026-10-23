import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/network_service.dart';

import 'container_service_test.dart' show snapshotPayload;

void main() {
  group('parseNetworkList', () {
    test('parses builtin + custom networks with subnets and labels', () {
      final json =
          '''
[
  ${'{"configuration":{"name":"default","mode":"nat","plugin":"builtin","labels":{"com.apple.container.resource.role":"builtin"}},"status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}}'},
  {"configuration":{"name":"backend","mode":"nat","plugin":"builtin","labels":{}},"status":{}}
]
''';

      final networks = NetworkService.parseNetworkList(json);

      expect(networks, hasLength(2));
      expect(networks[0].id, 'default');
      expect(networks[0].builtin, isTrue);
      expect(networks[0].subnet, '192.168.64.0/24');
      expect(networks[0].gateway, '192.168.64.1');
      expect(networks[1].id, 'backend');
      expect(networks[1].builtin, isFalse);
      expect(networks[1].subnet, isNull);
    });

    test('non-JSON output → INTERNAL', () {
      expect(
        () => NetworkService.parseNetworkList('not json'),
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

  group('listNetworks / getNetwork', () {
    late FakeContainerBridge bridge;
    late NetworkService service;

    setUp(() {
      bridge = FakeContainerBridge()
        ..networkListResult = const BridgeCommandResult(
          exitCode: 0,
          stdout:
              '[{"configuration":{"name":"default","mode":"nat","plugin":"builtin",'
              '"labels":{"com.apple.container.resource.role":"builtin"}},'
              '"status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}},'
              '{"configuration":{"name":"backend","mode":"nat","plugin":"builtin",'
              '"labels":{}},"status":{}}]',
          stderr: '',
        );
      service = NetworkService(
        bridge: bridge,
        containerService: ContainerService(bridge: bridge),
      );
    });

    test('joins member counts from container snapshots', () async {
      // web attaches to "default" (snapshotPayload default), other has none.
      bridge.containers = [
        snapshotPayload(id: 'web'),
        snapshotPayload(id: 'other', ip: null),
      ];

      final networks = await service.listNetworks();

      expect(networks, hasLength(2));
      expect(networks[0].id, 'default');
      expect(networks[0].containerCount, 1);
      expect(networks[0].builtin, isTrue);
      expect(networks[1].id, 'backend');
      expect(networks[1].containerCount, 0);
      expect(bridge.calls, contains('networkList'));
    });

    test('getNetwork returns members; unknown id → NOT_FOUND', () async {
      bridge.containers = [snapshotPayload(id: 'web')];

      final detail = await service.getNetwork('default');
      expect(detail.containers, hasLength(1));
      expect(detail.containers.single.containerId, 'web');
      expect(detail.containers.single.hostname, 'web');

      await expectLater(
        service.getNetwork('nope'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.notFound,
          ),
        ),
      );
    });

    test('CLI failure surfaces as INTERNAL with stderr hint', () async {
      bridge.networkListResult = const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error: service unavailable',
      );

      await expectLater(
        service.listNetworks(),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.internal)
              .having((e) => e.source, 'source', 'cli')
              .having((e) => e.hint, 'hint', 'Error: service unavailable'),
        ),
      );
    });
  });
}
