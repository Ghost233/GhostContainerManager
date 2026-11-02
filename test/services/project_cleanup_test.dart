import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/project_cleanup.dart';

import 'container_service_test.dart' show snapshotPayload;
import 'project_service_test.dart' show addImage;

void main() {
  late Directory temp;
  late FakeContainerBridge bridge;
  late ContainerService containers;
  late ProjectCleanup cleanup;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gcm-cleanup-');
    bridge = FakeContainerBridge();
    containers = ContainerService(bridge: bridge);
    cleanup = ProjectCleanup(
      directory: temp.path,
      containers: containers,
      images: ImageService(bridge: bridge, containerService: containers),
    );
  });

  tearDown(() async {
    await containers.dispose();
    await temp.delete(recursive: true);
  });

  Future<String> recordImage(
    String reference, {
    List<String> supersedes = const [],
    List<String> dependsOn = const [],
    bool keep = false,
  }) async {
    addImage(bridge, reference, project: 'demo');
    return (await cleanup.record(
          project: 'demo',
          kind: 'image',
          reference: reference,
          purpose: 'build',
          supersedes: supersedes,
          dependsOn: dependsOn,
          keep: keep,
        ))['id']
        as String;
  }

  Future<String> recordContainer(
    String id, {
    String state = 'stopped',
    bool resultsCollected = true,
  }) async {
    bridge.containers.add(
      snapshotPayload(
        id: id,
        status: state,
        labels: {'com.ghost233.project': 'demo'},
      ),
    );
    return (await cleanup.record(
          project: 'demo',
          kind: 'container',
          reference: id,
          purpose: 'test',
          temporary: true,
          resultsCollected: resultsCollected,
        ))['id']
        as String;
  }

  test(
    'relations persist across service restart; planning never deletes',
    () async {
      final old = await recordImage('demo-old:latest');
      await recordImage('demo-new:latest', supersedes: [old]);
      final restarted = ProjectCleanup(
        directory: temp.path,
        containers: containers,
        images: ImageService(bridge: bridge, containerService: containers),
      );
      expect(await restarted.resources('demo'), hasLength(2));
      final plan = await restarted.plan('demo');
      expect((plan['candidates'] as List).single['id'], old);
      expect(bridge.calls.where((c) => c.contains('Delete')), isEmpty);
    },
  );

  test(
    'only explicitly approved candidates are deleted; no stop or force',
    () async {
      final first = await recordContainer('test-one');
      final second = await recordContainer('test-two');
      final plan = await cleanup.plan('demo');
      final report = await cleanup.execute(
        project: 'demo',
        planId: plan['planId'] as String,
        approved: [first],
      );
      expect(report['deleted'], [first]);
      expect(bridge.calls, contains('containerDelete:test-one force=false'));
      expect(bridge.calls.any((c) => c.startsWith('containerStop')), isFalse);
      expect(bridge.containers, hasLength(1));
      expect((await cleanup.resources('demo')).single['id'], second);
      expect(
        () => cleanup.execute(
          project: 'demo',
          planId: plan['planId'] as String,
          approved: [second],
        ),
        throwsA(isA<GcmException>()),
      );
    },
  );

  test(
    'running, uncollected and unregistered resources are retained',
    () async {
      await recordContainer('running', state: 'running');
      await recordContainer('failed-test', resultsCollected: false);
      bridge.containers.add(
        snapshotPayload(id: 'unknown-old', status: 'stopped'),
      );
      final plan = await cleanup.plan('demo');
      expect(plan['candidates'], isEmpty);
      expect(plan['retained'], hasLength(2));
    },
  );

  test('container restarted after approval plan is skipped', () async {
    final id = await recordContainer('test');
    final plan = await cleanup.plan('demo');
    bridge.containers.single['status'] = 'running';
    final report = await cleanup.execute(
      project: 'demo',
      planId: plan['planId'] as String,
      approved: [id],
    );
    expect(report['deleted'], isEmpty);
    expect((report['skipped'] as List).single['reason'], 'running');
  });

  test('same name with new creation date is not deleted', () async {
    final id = await recordContainer('test');
    final plan = await cleanup.plan('demo');
    (bridge.containers.single['configuration'] as Map)['creationDate'] =
        '2026-10-30T12:00:00Z';
    final report = await cleanup.execute(
      project: 'demo',
      planId: plan['planId'] as String,
      approved: [id],
    );
    expect(report['deleted'], isEmpty);
    expect((report['skipped'] as List).single['reason'], 'identityChanged');
  });

  test(
    'retagged image and external container references are protected',
    () async {
      final old = await recordImage('demo-old:latest');
      await recordImage('demo-new:latest', supersedes: [old]);
      final plan = await cleanup.plan('demo');
      bridge.images.first['digest'] = 'sha256:other';
      final report = await cleanup.execute(
        project: 'demo',
        planId: plan['planId'] as String,
        approved: [old],
      );
      expect(report['deleted'], isEmpty);
      expect((report['skipped'] as List).single['reason'], 'identityChanged');
      bridge.images.first['digest'] =
          'sha256:${'demo-old:latest'.hashCode.abs()}';
      bridge.containers.add(
        snapshotPayload(
          id: 'external',
          image: 'demo-old:latest',
          status: 'stopped',
        ),
      );
      expect((await cleanup.plan('demo'))['candidates'], isEmpty);
    },
  );

  test('cross project dependency blocks cleanup and is rechecked', () async {
    final old = await recordImage('demo-old:latest');
    await recordImage('demo-new:latest', supersedes: [old]);
    final plan = await cleanup.plan('demo');
    addImage(bridge, 'other-api:latest', project: 'other');
    await cleanup.record(
      project: 'other',
      kind: 'image',
      reference: 'other-api:latest',
      purpose: 'build',
      dependsOn: [old],
    );
    final report = await cleanup.execute(
      project: 'demo',
      planId: plan['planId'] as String,
      approved: [old],
    );
    expect(report['deleted'], isEmpty);
    expect((report['skipped'] as List).single['reason'], 'dependency');
  });

  test(
    'unknown approvals and wrong project are rejected before deletion',
    () async {
      await recordContainer('test');
      final plan = await cleanup.plan('demo');
      for (final project in ['demo', 'other']) {
        await expectLater(
          () => cleanup.execute(
            project: project,
            planId: plan['planId'] as String,
            approved: ['unknown'],
          ),
          throwsA(isA<GcmException>()),
        );
      }
      expect(bridge.calls.where((c) => c.contains('Delete')), isEmpty);
    },
  );

  test('keep and changed relationship invalidate previous approval', () async {
    final id = await recordContainer('test');
    final plan = await cleanup.plan('demo');
    await cleanup.record(
      project: 'demo',
      kind: 'container',
      reference: 'test',
      purpose: 'debug',
      temporary: true,
      resultsCollected: true,
      keep: true,
    );
    final report = await cleanup.execute(
      project: 'demo',
      planId: plan['planId'] as String,
      approved: [id],
    );
    expect(report['deleted'], isEmpty);
    expect(report['skipped'], isNotEmpty);
  });
  test('expired and replaced plans cannot authorize cleanup', () async {
    var now = DateTime.utc(2026, 10, 30);
    cleanup = ProjectCleanup(
      directory: temp.path,
      containers: containers,
      images: ImageService(bridge: bridge, containerService: containers),
      clock: () => now,
    );
    final id = await recordContainer('test');
    final first = await cleanup.plan('demo');
    final second = await cleanup.plan('demo');
    await expectLater(
      () => cleanup.execute(
        project: 'demo',
        planId: first['planId'] as String,
        approved: [id],
      ),
      throwsA(isA<GcmException>()),
    );
    now = now.add(const Duration(minutes: 31));
    await expectLater(
      () => cleanup.execute(
        project: 'demo',
        planId: second['planId'] as String,
        approved: [id],
      ),
      throwsA(isA<GcmException>()),
    );
    expect(bridge.deleteCalls, 0);
  });

  test(
    'delete failures remain recorded and other approved items proceed',
    () async {
      final first = await recordContainer('fail');
      final second = await recordContainer('ok');
      bridge.writeFailures['delete:fail'] = 'runtime failure';
      final plan = await cleanup.plan('demo');
      final report = await cleanup.execute(
        project: 'demo',
        planId: plan['planId'] as String,
        approved: [first, second],
      );
      expect(report['deleted'], [second]);
      expect((report['failed'] as List).single['id'], first);
      expect((await cleanup.resources('demo')).single['id'], first);
    },
  );

  test(
    'relationship cycles, conflicting owners and corrupt storage fail closed',
    () async {
      final first = await recordImage('demo-one:latest');
      final second = await recordImage('demo-two:latest', dependsOn: [first]);
      await expectLater(
        () => cleanup.record(
          project: 'demo',
          kind: 'image',
          reference: 'demo-one:latest',
          purpose: 'dependency',
          dependsOn: [second],
        ),
        throwsA(isA<GcmException>()),
      );
      await expectLater(
        () => cleanup.record(
          project: 'other',
          kind: 'image',
          reference: 'demo-one:latest',
          purpose: 'build',
        ),
        throwsA(isA<GcmException>()),
      );
      await File('${temp.path}/demo.json').writeAsString('{broken');
      await expectLater(
        () => cleanup.plan('demo'),
        throwsA(isA<FormatException>()),
      );
      expect(bridge.deleteCalls, 0);
    },
  );

  test('same digest under a different tag protects external usage', () async {
    final old = await recordImage('demo-old:latest');
    await recordImage('demo-new:latest', supersedes: [old]);
    addImage(bridge, 'alias:latest');
    bridge.images.last['digest'] = bridge.images.first['digest'];
    bridge.containers.add(
      snapshotPayload(id: 'outside', image: 'alias:latest', status: 'stopped'),
    );
    final plan = await cleanup.plan('demo');
    expect(plan['candidates'], isEmpty);
    expect((plan['retained'] as List).first['reason'], 'containerReference');
  });

  test(
    'replacement must still exist; name reuse cannot authorize old cleanup',
    () async {
      final old = await recordImage('demo-old:latest');
      await recordImage('demo-new:latest', supersedes: [old]);
      bridge.images.removeLast();
      expect((await cleanup.plan('demo'))['candidates'], isEmpty);
    },
  );
  test(
    'container image identity and dependency are captured from runtime',
    () async {
      final image = await recordImage('demo-base:latest');
      final payload = snapshotPayload(
        id: 'dev',
        image: 'demo-base:latest',
        labels: {'com.ghost233.project': 'demo'},
      );
      ((payload['configuration'] as Map)['image'] as Map)['descriptor'] = {
        'digest': bridge.images.single['digest'],
      };
      bridge.containers.add(payload);
      final row = await cleanup.record(
        project: 'demo',
        kind: 'container',
        reference: 'dev',
        purpose: 'development',
      );
      expect(row['dependsOn'], [image]);
      expect(
        (row['usesImage'] as Map)['digest'],
        bridge.images.single['digest'],
      );
    },
  );
}
