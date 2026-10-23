import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_models.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';

/// Realistic apple/container 1.6.0 `ContainerSnapshot` payload (JSON-decoded
/// shape the Swift bridge produces).
Map<String, Object?> snapshotPayload({
  required String id,
  String image = 'docker.io/library/nginx:latest',
  String status = 'running',
  Map<String, String> labels = const {},
  String? ip = '192.168.64.3/24',
  String gateway = '192.168.64.1/24',
  String createdAt = '2026-10-20T08:00:00Z',
  String? startedAt = '2026-10-20T08:00:05Z',
}) {
  return <String, Object?>{
    'configuration': <String, Object?>{
      'id': id,
      'image': <String, Object?>{'reference': image},
      'labels': labels,
      'creationDate': createdAt,
      'stopSignal': 'SIGTERM',
      'initProcess': <String, Object?>{
        'executable': '/sbin/init',
        'arguments': <String>['--serve'],
        'environment': <String>['A=1', 'B=2'],
      },
      'publishedPorts': <Object?>[
        <String, Object?>{
          'hostAddress': '0.0.0.0',
          'hostPort': 8080,
          'containerPort': 80,
          'proto': 'tcp',
        },
      ],
    },
    'status': status,
    'networks': ip == null
        ? <Object?>[]
        : <Object?>[
            <String, Object?>{
              'network': 'default',
              'hostname': id,
              'ipv4Address': ip,
              'ipv4Gateway': gateway,
            },
          ],
    'startedDate': startedAt,
  };
}

void main() {
  late FakeContainerBridge bridge;
  late ContainerService service;

  setUp(() {
    bridge = FakeContainerBridge();
    service = ContainerService(
      bridge: bridge,
      foregroundInterval: const Duration(milliseconds: 50),
      backgroundInterval: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    service.stopPolling();
    await service.dispose();
  });

  group('parsing', () {
    test('snapshot payload parses into typed model', () async {
      bridge.containers = [
        snapshotPayload(
          id: 'web',
          labels: const {'com.ghost233.managed': 'true'},
        ),
      ];

      final list = await service.refresh();

      expect(list, hasLength(1));
      final c = list.single;
      expect(c.id, 'web');
      expect(c.image, 'docker.io/library/nginx:latest');
      expect(c.state, ContainerState.running);
      expect(c.labels['com.ghost233.managed'], 'true');
      expect(c.networks.single.network, 'default');
      expect(c.networks.single.address, '192.168.64.3');
      expect(c.networks.single.gateway, '192.168.64.1');
      expect(c.createdAt, DateTime.utc(2026, 10, 20, 8));
      expect(c.startedAt, DateTime.utc(2026, 10, 20, 8, 0, 5));
      expect(c.initCommand, '/sbin/init');
      expect(c.initArguments, ['--serve']);
      expect(c.environment, ['A=1', 'B=2']);
      expect(c.publishedPorts.single.hostPort, 8080);
      expect(c.stopSignal, 'SIGTERM');
      expect(c.rawConfiguration['id'], 'web');
    });

    test('payload missing configuration surfaces as INTERNAL', () async {
      bridge.containers = [
        <String, Object?>{'status': 'running'},
      ];

      await expectLater(
        service.refresh(),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.internal,
          ),
        ),
      );
    });

    test('unknown status string maps to ContainerState.unknown', () async {
      bridge.containers = [snapshotPayload(id: 'x', status: 'restarting')];

      final list = await service.refresh();

      expect(list.single.state, ContainerState.unknown);
    });
  });

  group('filtering (Service-layer semantics)', () {
    setUp(() {
      bridge.containers = [
        snapshotPayload(
          id: 'web',
          labels: const {'com.ghost233.compose.project': 'shop'},
        ),
        snapshotPayload(
          id: 'db',
          status: 'stopped',
          startedAt: null,
          labels: const {'com.ghost233.compose.project': 'shop'},
        ),
        snapshotPayload(
          id: 'other',
          labels: const {'com.ghost233.compose.project': 'blog'},
        ),
      ];
    });

    test('label filter is an exact key=value match', () async {
      final list = await service.listContainers(
        const ContainerQuery(label: 'com.ghost233.compose.project=shop'),
      );

      expect(list.map((c) => c.id), containsAll(['web', 'db']));
      expect(list.map((c) => c.id), isNot(contains('other')));
    });

    test('label filter does not substring-match values', () async {
      final list = await service.listContainers(
        const ContainerQuery(label: 'com.ghost233.compose.project=sho'),
      );

      expect(list, isEmpty);
    });

    test('malformed label (no =) matches nothing', () async {
      final list = await service.listContainers(
        const ContainerQuery(label: 'com.ghost233.compose.project'),
      );

      expect(list, isEmpty);
    });

    test('includeStopped=false keeps only running', () async {
      final list = await service.listContainers(
        const ContainerQuery(includeStopped: false),
      );

      expect(list.map((c) => c.id), ['web', 'other']);
    });

    test('status filter intersects with other filters', () async {
      final list = await service.listContainers(
        const ContainerQuery(
          state: ContainerState.stopped,
          label: 'com.ghost233.compose.project=shop',
        ),
      );

      expect(list.map((c) => c.id), ['db']);
    });
  });

  group('error mapping', () {
    test('connection invalid maps to RUNTIME_UNAVAILABLE with hint', () async {
      bridge.containerListThrows = true;

      await expectLater(
        service.refresh(),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.runtimeUnavailable)
              .having((e) => e.hint, 'hint', isNotNull),
        ),
      );
    });

    test('inspect unknown id maps to NOT_FOUND', () async {
      await expectLater(
        service.inspect('ghost'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.notFound,
          ),
        ),
      );
    });

    test('stats on non-running container maps to CONFLICT', () async {
      bridge.containers = [
        snapshotPayload(id: 'db', status: 'stopped', startedAt: null),
      ];
      bridge.statsFailures['db'] = 'container is not running';

      await expectLater(
        service.stats('db'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
    });

    test('decode failure maps to VERSION_MISMATCH', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      bridge.inspectFailures['web'] =
          'failed to decode response of type ContainerSnapshot';

      await expectLater(
        service.inspect('web'),
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

  group('inspect & stats', () {
    test('inspect returns full snapshot with configuration', () async {
      bridge.containers = [snapshotPayload(id: 'web')];

      final c = await service.inspect('web');

      expect(c.id, 'web');
      expect(c.rawConfiguration['stopSignal'], 'SIGTERM');
      expect(bridge.calls, contains('containerInspect:web'));
    });

    test('stats parses optional counters', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      bridge.statsResponses['web'] = <String, Object?>{
        'id': 'web',
        'memoryUsageBytes': 128 * 1024 * 1024,
        'memoryLimitBytes': 512 * 1024 * 1024,
        'numProcesses': 5,
      };

      final stats = await service.stats('web');

      expect(stats.memoryUsageBytes, 128 * 1024 * 1024);
      expect(stats.memoryUtilization, closeTo(0.25, 0.001));
      expect(stats.cpuUsageUsec, isNull);
      expect(stats.numProcesses, 5);
    });
  });

  group('adaptive polling', () {
    test('timer fires at foreground cadence and emits snapshots', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      final emissions = <List<ContainerSnapshotInfo>>[];
      final sub = service.snapshots.listen(emissions.add);

      service.startPolling(foreground: true);
      await Future<void>.delayed(const Duration(milliseconds: 130));
      service.stopPolling();
      await sub.cancel();

      expect(emissions, isNotEmpty);
      expect(
        bridge.calls.where((c) => c == 'containerList').length >= 2,
        isTrue,
      );
    });

    test('switching cadence re-schedules the timer', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      service.startPolling(foreground: true);
      service.startPolling(foreground: false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      service.stopPolling();

      // Background cadence is 200ms: no poll should have fired within 80ms.
      expect(bridge.calls.where((c) => c == 'containerList'), isEmpty);
    });

    test(
      'concurrent refresh returns last snapshot without stacking calls',
      () async {
        final completer = Completer<List<Map<String, Object?>>>();
        final blocking = _BlockingListBridge(completer);
        final blockingService = ContainerService(bridge: blocking);

        final first = blockingService.refresh();
        final second = await blockingService.refresh();

        expect(second, isEmpty);
        completer.complete(<Map<String, Object?>>[]);
        expect(await first, isEmpty);
        expect(blocking.listCalls, 1);
        await blockingService.dispose();
      },
    );
  });

  group('logs', () {
    test('multibyte UTF-8 split across chunks decodes intact', () async {
      // '汉' is E6 B1 89 in UTF-8 — split between the two bytes.
      final han = utf8.encode('汉');
      bridge.logResponses['web'] = [
        BridgeLogEvent.data(source: 'stdio', bytes: han.sublist(0, 1)),
        BridgeLogEvent.data(source: 'stdio', bytes: han.sublist(1)),
        const BridgeLogEvent.eof(),
      ];

      final events = await service.logs('web').toList();

      expect(events[0].kind, 'data');
      expect(events[0].text + events[1].text, '汉');
      expect(events.last.kind, 'eof');
    });

    test('boot and stdio sources stay separate', () async {
      bridge.logResponses['web'] = [
        BridgeLogEvent.data(source: 'boot', bytes: utf8.encode('kernel')),
        BridgeLogEvent.data(source: 'stdio', bytes: utf8.encode('app')),
        const BridgeLogEvent.eof(),
      ];

      final events = await service.logs('web').toList();

      expect(events[0].source, 'boot');
      expect(events[0].text, 'kernel');
      expect(events[1].source, 'stdio');
      expect(events[1].text, 'app');
    });

    test('error events surface with message', () async {
      bridge.logResponses['web'] = [const BridgeLogEvent.error('xpc died')];

      final events = await service.logs('web').toList();

      expect(events.single.kind, 'error');
      expect(events.single.message, 'xpc died');
    });
  });
}

/// Bridge whose containerList blocks until released, for concurrency tests.
class _BlockingListBridge extends FakeContainerBridge {
  _BlockingListBridge(this._gate);

  final Completer<List<Map<String, Object?>>> _gate;
  int listCalls = 0;

  @override
  Future<List<Map<String, Object?>>> containerList() {
    listCalls++;
    return _gate.future;
  }
}
