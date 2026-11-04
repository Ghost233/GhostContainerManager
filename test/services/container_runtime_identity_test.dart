import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_runtime_identity.dart';

void main() {
  final id = 'a' * 64;
  const op = 'operation-123';
  final labels = {
    ContainerRuntimeIdentityService.productLabel: 'true',
    ContainerRuntimeIdentityService.operationLabel: op,
  };
  BridgeCommandResult ok(String stdout) =>
      BridgeCommandResult(exitCode: 0, stdout: stdout, stderr: '');
  String inspected(
    String id, {
    String name = '/runtime',
    Map<String, String>? markers,
    Object? state,
  }) => jsonEncode([
    {
      'Id': id,
      'Name': name,
      'Config': {'Labels': markers ?? labels},
      'State': ?state,
    },
  ]);

  test(
    'create keeps distinct names and full ID, with reserved markers',
    () async {
      final calls = <List<String>>[];
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (args, _) async {
            calls.add(args);
            return ok('$id\n');
          },
        ),
      );
      final created = await service.create(
        businessName: 'business',
        runtimeName: 'runtime',
        operationId: op,
        image: 'example',
        labels: {'user': 'value'},
      );
      expect(created.businessName, 'business');
      expect(created.runtimeName, 'runtime');
      expect(created.fullId, id);
      expect(
        calls.single,
        containsAll([
          '--name',
          'runtime',
          '${ContainerRuntimeIdentityService.operationLabel}=$op',
          '${ContainerRuntimeIdentityService.productLabel}=true',
        ]),
      );
      await expectLater(
        service.create(
          businessName: 'business',
          runtimeName: 'runtime',
          operationId: op,
          image: 'example',
          labels: {ContainerRuntimeIdentityService.productLabel: 'false'},
        ),
        throwsArgumentError,
      );
      expect(calls.length, 1);
    },
  );

  test(
    'create rejects option injection and malformed label keys before execution',
    () async {
      final calls = <List<String>>[];
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (args, _) async {
            calls.add(args);
            return ok(id);
          },
        ),
      );
      for (final image in [
        '--name=other',
        '--label=${ContainerRuntimeIdentityService.productLabel}=false',
        ' --label=x=y',
      ]) {
        await expectLater(
          service.create(
            businessName: 'b',
            runtimeName: 'r',
            operationId: op,
            image: image,
          ),
          throwsArgumentError,
        );
      }
      for (final key in [
        '${ContainerRuntimeIdentityService.operationLabel}=other',
        '${ContainerRuntimeIdentityService.productLabel}=false',
        '',
        ' ${ContainerRuntimeIdentityService.productLabel}',
      ]) {
        await expectLater(
          service.create(
            businessName: 'b',
            runtimeName: 'r',
            operationId: op,
            image: 'example',
            labels: {key: 'x'},
          ),
          throwsArgumentError,
        );
      }
      expect(calls, isEmpty);
      await service.create(
        businessName: 'b',
        runtimeName: 'r',
        operationId: op,
        image: 'example',
        arguments: ['--name=not-a-docker-option'],
      );
      expect(calls.single.sublist(calls.single.length - 3), [
        '--',
        'example',
        '--name=not-a-docker-option',
      ]);
    },
  );

  test('invalid create result and failure never become identity', () async {
    for (final result in [
      ok(''),
      ok('abc'),
      ok('${'g' * 64}\n'),
      ok('$id\n$id'),
      const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'cannot connect',
      ),
      const BridgeCommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
        timedOut: true,
      ),
    ]) {
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(runner: (_, _) async => result),
      );
      await expectLater(
        service.create(
          businessName: 'b',
          runtimeName: 'r',
          operationId: op,
          image: 'i',
        ),
        throwsA(isA<BridgeCallException>()),
      );
    }
  });

  test(
    'fresh complete query inspects each full ID and exposes conflicts',
    () async {
      final other = 'b' * 64;
      final calls = <List<String>>[];
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (args, _) async {
            calls.add(args);
            if (args[1] == 'ls') return ok('$id\n$other\n');
            return ok(
              inspected(
                args.last,
                markers: args.last == other
                    ? {
                        ...labels,
                        ContainerRuntimeIdentityService.productLabel: 'false',
                      }
                    : labels,
              ),
            );
          },
        ),
      );
      final result = await service.queryOperation(op);
      expect(result.complete, isTrue);
      expect(result.matches, hasLength(2));
      expect(
        result.matches.first.matches(
          operationId: op,
          runtimeName: 'runtime',
          fullId: id,
        ),
        isTrue,
      );
      expect(
        result.matches.first.matches(
          operationId: op,
          runtimeName: 'different',
          fullId: id,
        ),
        isFalse,
      );
      expect(result.matches.last.hasProductMarker, isFalse);
      expect(calls, hasLength(3));
      expect(calls.first, contains('--no-trunc'));
    },
  );

  test(
    'query and inspection errors cannot appear as empty complete results',
    () async {
      for (final result in [
        const BridgeCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'cannot connect',
        ),
        const BridgeCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
          timedOut: true,
        ),
        const BridgeCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
          outputMayBeIncomplete: true,
        ),
        ok('short'),
        ok('$id\n$id'),
      ]) {
        final service = ContainerRuntimeIdentityService(
          DockerContainerBridge(runner: (_, _) async => result),
        );
        await expectLater(
          service.queryOperation(op),
          throwsA(isA<BridgeCallException>()),
        );
      }
      for (final output in [
        'not-json',
        '[]',
        inspected('b' * 64),
        inspected(
          id,
          markers: {
            ...labels,
            ContainerRuntimeIdentityService.operationLabel: 'other',
          },
        ),
        jsonEncode([
          {'Id': id, 'Name': '/runtime', 'Config': {}},
        ]),
      ]) {
        final service = ContainerRuntimeIdentityService(
          DockerContainerBridge(
            runner: (args, _) async => ok(args[1] == 'ls' ? id : output),
          ),
        );
        await expectLater(
          service.queryOperation(op),
          throwsA(isA<BridgeCallException>()),
        );
      }
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(runner: (_, _) async => ok('')),
      );
      expect((await service.queryOperation(op)).matches, isEmpty);
      await expectLater(service.inspect('short'), throwsArgumentError);
    },
  );

  test('lifecycle accepts only consistent stable states', () async {
    for (final (status, running, expected) in [
      ('running', true, RuntimeContainerLifecycle.running),
      ('created', false, RuntimeContainerLifecycle.stopped),
      ('exited', false, RuntimeContainerLifecycle.stopped),
      ('dead', false, RuntimeContainerLifecycle.stopped),
    ]) {
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (_, _) async =>
              ok(inspected(id, state: {'Status': status, 'Running': running})),
        ),
      );
      expect(
        await service.inspectLifecycle(
          fullId: id,
          runtimeName: 'runtime',
          operationId: op,
        ),
        expected,
      );
    }
    for (final state in [
      {'Status': 'paused', 'Running': true},
      {'Status': 'restarting', 'Running': true},
      {'Status': 'removing', 'Running': false},
      {'Status': 'unknown', 'Running': false},
      {'Status': 'running', 'Running': false},
      {'Status': 'exited', 'Running': true},
      {'Status': 'running'},
      <String, Object>{},
    ]) {
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (_, _) async => ok(inspected(id, state: state)),
        ),
      );
      await expectLater(
        service.inspectLifecycle(
          fullId: id,
          runtimeName: 'runtime',
          operationId: op,
        ),
        throwsA(isA<BridgeCallException>()),
      );
    }
  });

  test('start checks exact identity and verifies running by full ID', () async {
    final calls = <List<String>>[];
    var running = false;
    final service = ContainerRuntimeIdentityService(
      DockerContainerBridge(
        runner: (args, _) async {
          calls.add(args);
          if (args[1] == 'start') {
            running = true;
            return ok('$id\n');
          }
          return ok(
            inspected(
              id,
              state: {
                'Status': running ? 'running' : 'exited',
                'Running': running,
              },
            ),
          );
        },
      ),
    );
    expect(
      await service.start(fullId: id, runtimeName: 'runtime', operationId: op),
      RuntimeContainerLifecycle.running,
    );
    expect(calls, [
      ['container', 'inspect', id],
      ['container', 'start', id],
      ['container', 'inspect', id],
    ]);
    calls.clear();
    await service.start(fullId: id, runtimeName: 'runtime', operationId: op);
    expect(calls, [
      ['container', 'inspect', id],
    ]);
  });

  test('start fails closed for replacement, markers, runtime errors and unverified start', () async {
    final stopped = {'Status': 'exited', 'Running': false};
    final failure = BridgeCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'unreachable',
    );
    for (final response in [
      ok(inspected('b' * 64, state: stopped)),
      ok(inspected(id, name: '/replacement', state: stopped)),
      ok(
        inspected(
          id,
          markers: {
            ...labels,
            ContainerRuntimeIdentityService.productLabel: 'false',
          },
          state: stopped,
        ),
      ),
      ok(
        inspected(
          id,
          markers: {
            ...labels,
            ContainerRuntimeIdentityService.operationLabel: 'other',
          },
          state: stopped,
        ),
      ),
      ok(inspected(id, state: {'Status': 'paused', 'Running': true})),
      failure,
    ]) {
      final calls = <List<String>>[];
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (args, _) async {
            calls.add(args);
            return response;
          },
        ),
      );
      await expectLater(
        service.start(fullId: id, runtimeName: 'runtime', operationId: op),
        throwsA(isA<BridgeCallException>()),
      );
      expect(calls.every((args) => args[1] != 'start'), isTrue);
    }
    for (final startResponse in [failure, ok(id)]) {
      final calls = <List<String>>[];
      final service = ContainerRuntimeIdentityService(
        DockerContainerBridge(
          runner: (args, _) async {
            calls.add(args);
            return args[1] == 'start'
                ? startResponse
                : ok(inspected(id, state: stopped));
          },
        ),
      );
      await expectLater(
        service.start(fullId: id, runtimeName: 'runtime', operationId: op),
        throwsA(isA<BridgeCallException>()),
      );
      expect(calls[1], ['container', 'start', id]);
    }
    final calls = <List<String>>[];
    final service = ContainerRuntimeIdentityService(
      DockerContainerBridge(
        runner: (args, _) async {
          calls.add(args);
          return ok('');
        },
      ),
    );
    await expectLater(
      service.start(fullId: 'short', runtimeName: 'runtime', operationId: op),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });

  test('bridges without completeness contract fail closed', () async {
    final service = ContainerRuntimeIdentityService(FakeContainerBridge());
    await expectLater(
      service.queryOperation(op),
      throwsA(isA<BridgeCallException>()),
    );
    expect(
      BridgeCommandResult.fromMap({'exitCode': 0}).outputMayBeIncomplete,
      isTrue,
    );
  });

  test('bounded identity capture signals overflow', () async {
    final bridge = DockerContainerBridge(
      processStarter: (_) =>
          Process.start('/bin/sh', ['-c', 'yes x | head -c 9000000']),
    );
    final result = await bridge.cliRunForIdentity(['ignored']);
    expect(result.ok, isTrue);
    expect(result.outputMayBeIncomplete, isTrue);
    expect(result.stdout.length, lessThanOrEqualTo(8 * 1024 * 1024));
  });

  test('one-shot replay overflow is explicitly reported', () async {
    final bridge = DockerContainerBridge(
      processStarter: (_) => Process.start('/bin/sh', [
        '-c',
        'i=0; while [ \$i -lt 5100 ]; do echo line; i=\$((i+1)); done',
      ]),
    );
    final result = await bridge.cliRun(['ignored']);
    expect(result.ok, isTrue);
    expect(result.outputMayBeIncomplete, isTrue);
  });
}
