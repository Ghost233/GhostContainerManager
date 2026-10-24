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

  group('one-shot exec', () {
    test(
      'preserves a non-zero exit code and caps each UTF-8 output stream',
      () async {
        bridge.containers = [snapshotPayload(id: 'web')];
        await service.refresh();
        final ascii = List.filled(64 * 1024 - 1, 'a').join();
        final stderrBytes = List.filled(64 * 1024 + 100, 'e').join();
        bridge.execResult = BridgeExecResult(
          exitCode: 42,
          stdout: '$ascii中discarded',
          stderr: stderrBytes,
        );

        final result = await service.exec(
          'web',
          command: ['sh', '-c', 'exit 42'],
          env: const {'MODE': 'prod'},
          workdir: '/srv',
          user: 'www',
          timeoutSeconds: 12,
        );

        expect(result.exitCode, 42);
        expect(result.stdout, ascii);
        expect(result.stderr, List.filled(64 * 1024, 'e').join());
        expect(utf8.encode(result.stdout).length, lessThanOrEqualTo(64 * 1024));
        expect(utf8.encode(result.stderr).length, 64 * 1024);
        expect(result.stdoutTruncated, isTrue);
        expect(result.stderrTruncated, isTrue);
        expect(result.truncated, isTrue);
        expect(bridge.execRequests.single, {
          'id': 'web',
          'command': ['sh', '-c', 'exit 42'],
          'env': ['MODE=prod'],
          'workdir': '/srv',
          'user': 'www',
          'timeoutSeconds': 12,
        });
      },
    );
  });

  group('write lifecycle', () {
    test(
      'create forwards configuration and exposes creating immediately',
      () async {
        final gate = Completer<void>();
        bridge.createGate = gate;
        final future = service.create(
          id: 'web',
          image: 'nginx:latest',
          command: const ['nginx', '-g', 'daemon off;'],
          env: const ['MODE=production'],
          ports: const ['8080:80/tcp'],
          network: 'frontend',
          mounts: const [
            {'source': '/tmp/gcm-data', 'target': '/data', 'readonly': true},
          ],
          labels: const {'com.ghost233.project': 'demo'},
        );

        expect(service.activityFor('web'), ContainerActivity.creating);
        expect(
          service.currentContainers.single.id,
          'web',
          reason: 'a newly created resource must not wait for the next poll',
        );
        expect(bridge.createRequests.single, <String, Object?>{
          'id': 'web',
          'image': 'nginx:latest',
          'command': const ['nginx', '-g', 'daemon off;'],
          'env': const ['MODE=production'],
          'ports': const ['8080:80/tcp'],
          'network': 'frontend',
          'mounts': const [
            {'source': '/tmp/gcm-data', 'target': '/data', 'readonly': true},
          ],
          'labels': const {'com.ghost233.project': 'demo'},
        });
        gate.complete();
        expect(await future, 'web');
        expect(service.activityFor('web'), isNull);
        expect(service.currentContainers.single.state, ContainerState.stopped);
      },
    );

    test(
      'refresh retains an optimistic create in the broadcast snapshot',
      () async {
        final events = <List<ContainerSnapshotInfo>>[];
        final subscription = service.snapshots.listen(events.add);
        addTearDown(subscription.cancel);
        final gate = Completer<void>();
        bridge.createGate = gate;
        final creating = service.create(id: 'web', image: 'nginx:latest');
        events.clear();

        final refreshed = await service.refresh();
        await Future<void>.delayed(Duration.zero);

        expect(refreshed.map((container) => container.id), ['web']);
        expect(events, isNotEmpty);
        expect(events.last.map((container) => container.id), ['web']);
        expect(events.last.single.state, ContainerState.stopped);
        gate.complete();
        await creating;
      },
    );

    test(
      'create start failure exposes the created resource in error details',
      () async {
        bridge.writeFailures['start:web'] = 'bootstrap failed';

        Object? failure;
        try {
          await service.create(id: 'web', image: 'nginx:latest', start: true);
        } catch (error) {
          failure = error;
        }

        final error = failure as GcmException;
        final wire = error.toWire()['error']! as Map<String, Object?>;
        expect(wire['details'], <String, Object?>{
          'id': 'web',
          'created': true,
        });
        expect(service.currentContainers.single.id, 'web');
        expect(service.currentContainers.single.state, ContainerState.stopped);
      },
    );

    test(
      'concurrent creates never coalesce, even with different images',
      () async {
        bridge.createGate = Completer<void>();
        final first = service.create(id: 'web', image: 'nginx:latest');

        await expectLater(
          service.create(id: 'web', image: 'redis:latest'),
          throwsA(
            isA<GcmException>().having(
              (error) => error.code,
              'code',
              GcmErrorCode.conflict,
            ),
          ),
        );
        await expectLater(
          service.create(id: 'web', image: 'nginx:latest'),
          throwsA(isA<GcmException>()),
        );
        expect(bridge.createRequests, hasLength(1));

        bridge.createGate!.complete();
        await first;
      },
    );

    test('different stop timeouts queue instead of joining', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      bridge.stopGate = Completer<void>();
      final first = service.stop('web', timeoutSeconds: 5);
      final second = service.stop('web', timeoutSeconds: 7);

      expect(bridge.stopCalls, 1);
      bridge.stopGate!.complete();
      await Future.wait([first, second]);
      expect(bridge.stopCalls, 2);
      expect(
        bridge.calls.where((call) => call.startsWith('containerStop')),
        <String>['containerStop:web timeout=5', 'containerStop:web timeout=7'],
      );
    });

    test('dispose completes in-flight writes instead of hanging', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      bridge.stopGate = Completer<void>();
      final pending = service.stop('web');
      expect(bridge.stopCalls, 1);
      final expectation = expectLater(
        pending.timeout(const Duration(milliseconds: 100)),
        throwsA(isA<GcmException>()),
      );

      await service.dispose();

      await expectation;
      bridge.stopGate!.complete();
    });

    test(
      'different delete force values never share an operation future',
      () async {
        bridge.containers = [snapshotPayload(id: 'web')];
        bridge.deleteGate = Completer<void>();

        final forced = service.delete('web', force: true);
        final unforced = service.delete('web');

        expect(identical(forced, unforced), isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(bridge.deleteCalls, 1);
        bridge.deleteGate!.complete();
        await Future.wait([forced, unforced]);
        expect(bridge.deleteCalls, 1);
      },
    );

    test('stop and kill return their native result contracts', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      bridge.stoppedGracefully = false;
      expect(await service.stop('web'), isFalse);

      bridge.containers = [snapshotPayload(id: 'web')];
      expect(await service.kill('web', signal: 'sigterm'), 'running');
      expect(bridge.killRequests.single['signal'], 'TERM');
    });

    test(
      'local image choices come from the existing bridge without pulling',
      () async {
        bridge.images = <Map<String, Object?>>[
          <String, Object?>{'reference': 'docker.io/library/nginx:latest'},
        ];

        final images = await service.listLocalImages();

        expect(images.single.reference, 'docker.io/library/nginx:latest');
        expect(bridge.calls, contains('imageList'));
        expect(
          bridge.calls.where((call) => call.startsWith('imagePull')),
          isEmpty,
        );
      },
    );

    test(
      'create and kill reject invalid ids, ports, mounts, and signals',
      () async {
        Future<void> expectInvalid(Future<dynamic> Function() body) async {
          try {
            await body();
            fail('Expected INVALID_ARGUMENT');
          } on GcmException catch (error) {
            expect(error.code, GcmErrorCode.invalidArgument);
          }
        }

        await expectInvalid(
          () => service.create(
            id: List.filled(65, 'a').join(),
            image: 'nginx:latest',
          ),
        );
        for (final port in <String>[
          '',
          '8080',
          '0:80',
          '8080:65536',
          '8080:80/sctp',
          '127.0.0.1:8080:80/tcp',
        ]) {
          await expectInvalid(
            () =>
                service.create(id: 'web', image: 'nginx:latest', ports: [port]),
          );
        }
        await expectInvalid(
          () => service.create(
            id: 'web',
            image: 'nginx:latest',
            mounts: const [
              {'source': '/tmp/data', 'target': 'relative/data'},
            ],
          ),
        );
        for (final signal in <String>['', '9', 'BOGUS', 'KILL -9']) {
          await expectInvalid(() => service.kill('web', signal: signal));
        }
        expect(bridge.createRequests, isEmpty);
        expect(bridge.killRequests, isEmpty);
      },
    );

    test('stop and restart reject timeouts outside the runtime range', () {
      for (final timeout in <int>[-1, 2147483648]) {
        expect(
          () => service.stop('web', timeoutSeconds: timeout),
          throwsA(
            isA<GcmException>().having(
              (error) => error.code,
              'code',
              GcmErrorCode.invalidArgument,
            ),
          ),
        );
        expect(
          () => service.restart('web', timeoutSeconds: timeout),
          throwsA(
            isA<GcmException>().having(
              (error) => error.code,
              'code',
              GcmErrorCode.invalidArgument,
            ),
          ),
        );
      }
      expect(bridge.stopCalls, 0);
      expect(bridge.startCalls, 0);
    });

    test('same start joins one call and different operations queue', () async {
      bridge.containers = [snapshotPayload(id: 'web', status: 'stopped')];
      bridge.startGate = Completer<void>();
      final first = service.start('web');
      final duplicate = service.start('web');
      final queuedStop = service.stop('web');
      final duplicateStop = service.stop('web');

      expect(bridge.startCalls, 1);
      expect(bridge.stopCalls, 0);
      expect(service.activityFor('web'), ContainerActivity.starting);
      bridge.startGate!.complete();
      await Future.wait([first, duplicate, queuedStop, duplicateStop]);

      expect(bridge.startCalls, 1);
      expect(bridge.stopCalls, 1);
      expect(
        bridge.calls.where((call) => call.startsWith('container')).toList(),
        <String>['containerStart:web', 'containerStop:web timeout=5'],
      );
    });

    test(
      'restart coalesces and remains restarting across stop and start',
      () async {
        bridge.containers = [snapshotPayload(id: 'web')];
        bridge.stopGate = Completer<void>();
        final first = service.restart('web');
        final duplicate = service.restart('web');

        expect(service.activityFor('web'), ContainerActivity.restarting);
        expect(bridge.stopCalls, 1);
        expect(bridge.startCalls, 0);
        bridge.stopGate!.complete();
        await Future.wait([first, duplicate]);

        expect(bridge.stopCalls, 1);
        expect(bridge.startCalls, 1);
        expect(service.activityFor('web'), isNull);
      },
    );

    test('delete rejects an in-flight stop even when forced', () async {
      bridge.containers = [snapshotPayload(id: 'web')];
      bridge.stopGate = Completer<void>();
      final stopping = service.stop('web');

      await expectLater(
        service.delete('web', force: true),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.conflict)
              .having((e) => e.hint, 'hint', contains('停止')),
        ),
      );
      expect(bridge.deleteCalls, 0);
      bridge.stopGate!.complete();
      await stopping;
    });

    test('delete rejects a stop queued behind another write', () async {
      bridge.containers = [snapshotPayload(id: 'web', status: 'stopped')];
      bridge.startGate = Completer<void>();
      final starting = service.start('web');
      final stopping = service.stop('web');
      final deleteCheck = expectLater(
        service.delete('web', force: true),
        throwsA(
          isA<GcmException>().having(
            (error) => error.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );

      bridge.startGate!.complete();
      await Future.wait([starting, stopping]);
      await deleteCheck;
      expect(bridge.deleteCalls, 0);
    });

    test(
      'delete requires force for running and ignores a repeated not found',
      () async {
        bridge.containers = [snapshotPayload(id: 'web')];
        await expectLater(
          service.delete('web'),
          throwsA(
            isA<GcmException>().having(
              (e) => e.code,
              'code',
              GcmErrorCode.conflict,
            ),
          ),
        );

        await service.delete('web', force: true);
        await service.delete('web', force: true);
        expect(bridge.deleteCalls, 1);
        expect(service.currentContainers, isEmpty);
      },
    );

    test('delete rejects native stopping regardless of force', () async {
      bridge.containers = [snapshotPayload(id: 'web', status: 'stopping')];
      await service.refresh();

      await expectLater(
        service.delete('web', force: true),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
      expect(bridge.deleteCalls, 0);
    });

    test('duplicate create failure preserves the existing snapshot', () async {
      bridge.containers = [
        snapshotPayload(id: 'web', status: 'stopped', startedAt: null),
      ];
      await service.refresh();

      await expectLater(
        service.create(id: 'web', image: 'nginx:latest'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
      expect(service.currentContainers.single.id, 'web');
      expect(service.currentContainers.single.state, ContainerState.stopped);
    });

    test(
      'kill forwards KILL by default and clears activity on failure',
      () async {
        bridge.containers = [snapshotPayload(id: 'web')];
        await service.kill('web');
        expect(bridge.killRequests.single, <String, Object?>{
          'id': 'web',
          'signal': 'KILL',
        });

        bridge.writeFailures['start:web'] = 'runtime connection is invalid';
        final starting = service.start('web');
        expect(service.activityFor('web'), ContainerActivity.starting);
        await expectLater(
          starting,
          throwsA(
            isA<GcmException>().having(
              (e) => e.code,
              'code',
              GcmErrorCode.runtimeUnavailable,
            ),
          ),
        );
        expect(service.activityFor('web'), isNull);
      },
    );
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

  group('stats history', () {
    test(
      'foreground polling records counters and emits read-only snapshots',
      () async {
        final statsBridge = _StatsSequenceBridge(maximumSamples: 2)
          ..containers = [snapshotPayload(id: 'web')];
        final historyService = ContainerService(
          bridge: statsBridge,
          foregroundInterval: const Duration(milliseconds: 5),
          backgroundInterval: const Duration(milliseconds: 50),
        );
        addTearDown(historyService.dispose);
        historyService.setStatsTarget('web');
        final sampled = Completer<void>();
        var notifications = 0;
        final subscription = historyService.statsHistoryChanges.listen((_) {
          notifications++;
          if (historyService.statsHistoryFor('web').length >= 2 &&
              !sampled.isCompleted) {
            sampled.complete();
          }
        });
        addTearDown(subscription.cancel);

        historyService.startPolling(foreground: true);
        await sampled.future.timeout(const Duration(seconds: 5));

        final history = historyService.statsHistoryFor('web');
        expect(history, hasLength(2));
        expect(history.first.cpuPercent, isNull);
        expect(history.last.cpuPercent, isNotNull);
        expect(history.last.cpuPercent!, greaterThan(0));
        expect(history.map((sample) => sample.memoryBytes), [1, 2]);
        expect(history.map((sample) => sample.networkRxBytes), [10, 20]);
        expect(history.map((sample) => sample.networkTxBytes), [20, 40]);
        expect(history.map((sample) => sample.diskReadBytes), [100, 200]);
        expect(history.map((sample) => sample.diskWriteBytes), [200, 400]);
        expect(
          history.last.timestamp.isBefore(history.first.timestamp),
          isFalse,
        );
        expect(notifications, greaterThanOrEqualTo(2));
        expect(historyService.statsHistoryFor('db'), isEmpty);
        expect(() => history.add(history.first), throwsUnsupportedError);
      },
    );

    test('keeps the newest 450 samples in chronological order', () async {
      final statsBridge = _StatsSequenceBridge(maximumSamples: 451)
        ..containers = [snapshotPayload(id: 'web')];
      final historyService = ContainerService(
        bridge: statsBridge,
        foregroundInterval: const Duration(milliseconds: 1),
        backgroundInterval: const Duration(milliseconds: 50),
      );
      addTearDown(historyService.dispose);
      historyService.setStatsTarget('web');
      final sampled = Completer<void>();
      final subscription = historyService.statsHistoryChanges.listen((_) {
        if (statsBridge.statsCalls >= 451 && !sampled.isCompleted) {
          sampled.complete();
        }
      });
      addTearDown(subscription.cancel);

      historyService.startPolling(foreground: true);
      await sampled.future.timeout(const Duration(seconds: 5));

      final history = historyService.statsHistoryFor('web');
      expect(history, hasLength(450));
      expect(history.first.memoryBytes, 2);
      expect(history.last.memoryBytes, 451);
      for (var index = 1; index < history.length; index++) {
        expect(
          history[index].timestamp.isBefore(history[index - 1].timestamp),
          isFalse,
        );
      }
    });

    test(
      'changing target clears histories and restarts the CPU baseline',
      () async {
        final statsBridge = _StatsSequenceBridge(
          maximumSamples: 4,
        )..containers = [snapshotPayload(id: 'web'), snapshotPayload(id: 'db')];
        final historyService = ContainerService(
          bridge: statsBridge,
          foregroundInterval: const Duration(milliseconds: 5),
          backgroundInterval: const Duration(milliseconds: 50),
        );
        addTearDown(historyService.dispose);
        final webSampled = Completer<void>();
        final dbSampled = Completer<void>();
        final notifications = <List<ContainerStatsSample>>[];
        final subscription = historyService.statsHistoryChanges.listen((
          history,
        ) {
          notifications.add(history);
          if (historyService.statsHistoryFor('web').length >= 2 &&
              !webSampled.isCompleted) {
            webSampled.complete();
          }
          if (historyService.statsHistoryFor('db').length >= 2 &&
              !dbSampled.isCompleted) {
            dbSampled.complete();
          }
        });
        addTearDown(subscription.cancel);

        historyService.setStatsTarget('web');
        historyService.startPolling(foreground: true);
        await webSampled.future.timeout(const Duration(seconds: 5));
        historyService.stopPolling();
        expect(historyService.statsHistoryFor('web'), hasLength(2));

        notifications.clear();
        historyService.setStatsTarget('db');
        expect(historyService.statsHistoryFor('web'), isEmpty);
        expect(historyService.statsHistoryFor('db'), isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(notifications, isNotEmpty);
        expect(notifications.last, isEmpty);

        historyService.startPolling(foreground: true);
        await dbSampled.future.timeout(const Duration(seconds: 5));
        historyService.stopPolling();
        final dbHistory = historyService.statsHistoryFor('db');
        expect(dbHistory.map((sample) => sample.memoryBytes), [3, 4]);
        expect(dbHistory.first.cpuPercent, isNull);
        expect(dbHistory.last.cpuPercent, isNotNull);

        historyService.setStatsTarget(null);
        expect(historyService.statsHistoryFor('db'), isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(notifications.last, isEmpty);

        historyService.setStatsTarget('web');
        expect(historyService.statsHistoryFor('web'), isEmpty);
      },
    );

    test(
      'foreground transitions clear history and suspend stats sampling',
      () async {
        final statsBridge = _StatsSequenceBridge(maximumSamples: 3)
          ..containers = [snapshotPayload(id: 'web')];
        final historyService = ContainerService(
          bridge: statsBridge,
          foregroundInterval: const Duration(milliseconds: 5),
          backgroundInterval: const Duration(milliseconds: 20),
        );
        addTearDown(historyService.dispose);
        historyService.setStatsTarget('web');
        final sampled = Completer<void>();
        final resumed = Completer<void>();
        final notifications = <List<ContainerStatsSample>>[];
        final subscription = historyService.statsHistoryChanges.listen((
          history,
        ) {
          notifications.add(history);
          if (statsBridge.statsCalls >= 2 && !sampled.isCompleted) {
            sampled.complete();
          }
          if (statsBridge.statsCalls >= 3 &&
              history.isNotEmpty &&
              !resumed.isCompleted) {
            resumed.complete();
          }
        });
        addTearDown(subscription.cancel);

        historyService.startPolling(foreground: true);
        await sampled.future.timeout(const Duration(seconds: 5));
        historyService.startPolling(foreground: false);
        expect(historyService.statsHistoryFor('web'), isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(statsBridge.statsCalls, 2);
        expect(notifications.last, isEmpty);

        historyService.startPolling(foreground: true);
        await resumed.future.timeout(const Duration(seconds: 5));
        historyService.stopPolling();
        final history = historyService.statsHistoryFor('web');
        expect(history, hasLength(1));
        expect(history.single.memoryBytes, 3);
        expect(history.single.cpuPercent, isNull);
      },
    );
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
      'an in-flight foreground tick cannot revive after a background switch',
      () async {
        final gate = Completer<List<Map<String, Object?>>>();
        final blocking = _BlockingListBridge(gate);
        final blockingService = ContainerService(
          bridge: blocking,
          foregroundInterval: const Duration(milliseconds: 5),
          backgroundInterval: const Duration(seconds: 1),
        );
        addTearDown(blockingService.dispose);
        blockingService.startPolling(foreground: true);
        for (
          var attempt = 0;
          attempt < 100 && blocking.listCalls == 0;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(blocking.listCalls, 1);

        blockingService.startPolling(foreground: false);
        gate.complete(<Map<String, Object?>>[]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        blockingService.stopPolling();

        expect(blocking.listCalls, 1);
      },
    );

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

  group('task-30 error mapping regressions', () {
    test('timeout and invalid port/signal/network map to stable codes', () {
      final cases = <(String, GcmErrorCode)>[
        ('operation timed out', GcmErrorCode.timeout),
        ('invalid published port 70000', GcmErrorCode.invalidArgument),
        ('unknown signal BOGUS', GcmErrorCode.invalidArgument),
        ('network "frontend" not found', GcmErrorCode.invalidArgument),
      ];

      for (final (message, code) in cases) {
        final error = mapContainerFailure(
          BridgeCallException(message),
          operation: 'create',
          id: 'web',
        );
        expect(error.code, code, reason: message);
      }
    });

    test(
      'create identifies a missing local image and points to image_pull',
      () {
        final error = mapContainerFailure(
          const BridgeCallException(
            'image with reference nginx:latest not found',
          ),
          operation: 'create',
          id: 'web',
          image: 'nginx:latest',
        );

        expect(error.code, GcmErrorCode.notFound);
        expect(error.message, contains('nginx:latest'));
        expect(error.message, contains('locally'));
        expect(error.message, isNot(contains('Container "web" was not found')));
        expect(error.hint, '先在镜像页拉取或调用 image_pull');
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

/// Deterministic cumulative stats for public ContainerService history tests.
class _StatsSequenceBridge extends FakeContainerBridge {
  _StatsSequenceBridge({required this.maximumSamples});

  final int maximumSamples;
  int statsCalls = 0;

  @override
  Future<Map<String, Object?>> containerStats(String id) async {
    if (statsCalls >= maximumSamples) {
      throw const BridgeCallException('stats sequence exhausted');
    }
    statsCalls += 1;
    final sequence = statsCalls;
    return <String, Object?>{
      'cpuUsageUsec': sequence * 1000000,
      'memoryUsageBytes': sequence,
      'memoryLimitBytes': 1024,
      'networkRxBytes': sequence * 10,
      'networkTxBytes': sequence * 20,
      'blockReadBytes': sequence * 100,
      'blockWriteBytes': sequence * 200,
      'numProcesses': 1,
    };
  }
}
