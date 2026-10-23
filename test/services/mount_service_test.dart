import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/mount_service.dart';

import 'container_service_test.dart' show snapshotPayload;

/// Injects a mounts array into a snapshot payload (CLI 1.5.0 wire shape:
/// `{"destination", "options": ["ro"], "source", "type": {"virtiofs": {}}}`).
Map<String, Object?> payloadWithMounts(
  String id,
  List<Map<String, Object?>> mounts, {
  String status = 'running',
}) {
  final payload = snapshotPayload(
    id: id,
    status: status,
    startedAt: status == 'running' ? '2026-10-20T08:00:05Z' : null,
  );
  (payload['configuration'] as Map<String, Object?>)['mounts'] = mounts;
  return payload;
}

Map<String, Object?> virtiofsMount(
  String source,
  String destination, {
  bool readOnly = false,
}) {
  return <String, Object?>{
    'destination': destination,
    'options': readOnly ? <String>['ro'] : <String>[],
    'source': source,
    'type': <String, Object?>{'virtiofs': <String, Object?>{}},
  };
}

void main() {
  late FakeContainerBridge bridge;
  late MountService service;

  setUp(() {
    bridge = FakeContainerBridge();
    service = MountService(containerService: ContainerService(bridge: bridge));
  });

  test('aggregates one source mounted by two containers', () async {
    bridge.containers = [
      payloadWithMounts('web', [
        virtiofsMount('/Users/x/site', '/usr/share', readOnly: true),
      ]),
      payloadWithMounts('db', [virtiofsMount('/Users/x/site', '/data')]),
    ];

    final mounts = await service.listMounts();

    expect(mounts, hasLength(1));
    final mount = mounts.single;
    expect(mount.name, '/Users/x/site');
    expect(mount.type, 'virtiofs');
    expect(mount.source, '/Users/x/site');
    expect(mount.usedBy, hasLength(2));
    expect(mount.usedBy[0].containerId, 'web');
    expect(mount.usedBy[0].destination, '/usr/share');
    expect(mount.usedBy[0].readOnly, isTrue);
    expect(mount.usedBy[1].containerId, 'db');
    expect(mount.usedBy[1].readOnly, isFalse);
    expect(mount.fullyReadOnly, isFalse); // db mounts it read-write
  });

  test('tmpfs mounts are keyed tmpfs:<destination> with null source', () async {
    bridge.containers = [
      payloadWithMounts('web', [
        <String, Object?>{
          'destination': '/cache',
          'options': <String>[],
          'type': <String, Object?>{'tmpfs': <String, Object?>{}},
        },
      ]),
    ];

    final mount = (await service.listMounts()).single;

    expect(mount.name, 'tmpfs:/cache');
    expect(mount.type, 'tmpfs');
    expect(mount.source, isNull);
    expect(mount.usedBy.single.readOnly, isFalse);
    expect(mount.fullyReadOnly, isFalse);
  });

  test('stopped containers contribute their mounts too', () async {
    bridge.containers = [
      payloadWithMounts('db', [
        virtiofsMount('/Users/x/data', '/data'),
      ], status: 'stopped'),
    ];

    final mounts = await service.listMounts();

    expect(mounts.single.usedBy.single.containerId, 'db');
  });

  test('no mounts anywhere → empty list', () async {
    bridge.containers = [snapshotPayload(id: 'web')];

    expect(await service.listMounts(), isEmpty);
  });

  test(
    'inspectMount returns the aggregate; unknown name → NOT_FOUND',
    () async {
      bridge.containers = [
        payloadWithMounts('web', [
          virtiofsMount('/Users/x/site', '/usr/share', readOnly: true),
        ]),
      ];

      final mount = await service.inspectMount('/Users/x/site');
      expect(mount.usedBy.single.containerId, 'web');
      expect(mount.fullyReadOnly, isTrue);

      await expectLater(
        service.inspectMount('/nope'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.notFound,
          ),
        ),
      );
    },
  );
}
