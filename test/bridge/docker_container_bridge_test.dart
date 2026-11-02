import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/container_models.dart';
import 'package:ghost_container_manager/services/image_models.dart';

void main() {
  test('Docker inspect maps identity, references, named volumes, ports and stopped state', () {
    final snapshot = ContainerSnapshotInfo.fromMap(
      DockerContainerBridge.normalizeContainer({
        'Id': 'abc',
        'Name': '/web',
        'Created': '2026-11-02T01:00:00Z',
        'Image': 'sha256:123',
        'State': {'Status': 'exited'},
        'Config': {
          'Image': 'app:v1',
          'Labels': {'com.docker.compose.project': 'app'},
          'Env': ['X=1'],
        },
        'Mounts': [
          {
            'Type': 'volume',
            'Name': 'deps',
            'Source': '/engine/volumes/deps',
            'Destination': '/cache',
            'RW': false,
          },
        ],
        'NetworkSettings': {
          'Networks': {
            'app_default': {'IPAddress': '172.18.0.2', 'Gateway': '172.18.0.1'},
          },
          'Ports': {
            '80/tcp': [
              {'HostIp': '127.0.0.1', 'HostPort': '8080'},
            ],
          },
        },
      }),
    );
    expect(snapshot.id, 'web');
    expect(snapshot.image, 'app:v1');
    expect(snapshot.state, ContainerState.stopped);
    expect(snapshot.createdAt, DateTime.utc(2026, 11, 2, 1));
    expect(snapshot.rawConfiguration['image'], {
      'reference': 'app:v1',
      'descriptor': {'digest': 'sha256:123'},
    });
    expect(
      (snapshot.rawConfiguration['mounts'] as List).single['source'],
      'deps',
    );
    expect(snapshot.networks.single.address, '172.18.0.2');
    expect(snapshot.publishedPorts.single.hostPort, 8080);
  });
  test(
    'empty daemon inventories do not call inspect with empty argv',
    () async {
      final calls = <List<String>>[];
      final bridge = DockerContainerBridge(
        runner: (args, _) async {
          calls.add(args);
          return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      expect(await bridge.containerList(), isEmpty);
      expect(await bridge.imageList(), isEmpty);
      expect(calls.length, 2);
    },
  );
  test(
    'create preserves arguments as separate argv and forwards Docker flags',
    () async {
      late List<String> seen;
      final bridge = DockerContainerBridge(
        runner: (args, _) async {
          seen = args;
          return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await bridge.containerCreate(
        id: 'app',
        image: 'app:v1',
        command: ['echo', r'literal $(touch bad)'],
        env: ['A=hello world'],
        mounts: [
          {'source': '/a b', 'target': '/src', 'readonly': true},
        ],
      );
      expect(
        seen,
        containsAllInOrder([
          'container',
          'create',
          '--name',
          'app',
          '--env',
          'A=hello world',
          '--mount',
          'type=bind,source=/a b,target=/src,readonly',
          'app:v1',
          'echo',
          r'literal $(touch bad)',
        ]),
      );
    },
  );
  test(
    'image inspect uses Docker config and accepts immutable references',
    () async {
      final bridge = DockerContainerBridge(
        runner: (args, _) async => BridgeCommandResult(
          exitCode: 0,
          stdout: jsonEncode([
            {
              'Id': 'sha256:abc',
              'Size': 123,
              'Os': 'linux',
              'Architecture': 'arm64',
              'RootFS': {
                'Layers': ['a'],
              },
              'Config': {
                'Labels': {'x': 'y'},
                'Cmd': ['app'],
              },
            },
          ]),
          stderr: '',
        ),
      );
      final result = ImageInspection.fromMap(
        await bridge.imageInspect('sha256:abc'),
      );
      expect(result.sizeBytes, 123);
      expect(result.layers, 1);
      expect(result.cmd, ['app']);
      expect(result.labels, {'x': 'y'});
      final digest = 'sha256:${'a' * 64}';
      expect(validateImageReference(digest).reference, digest);
      expect(validateImageReference('app@$digest').reference, 'app@$digest');
    },
  );
  test(
    'process output and real exit code survive late subscriptions',
    () async {
      final bridge = DockerContainerBridge(executable: '/bin/sh');
      final process = bridge.cliStart([
        '-c',
        'printf "hello\\n"; printf "problem\\n" >&2; exit 7',
      ]);
      expect(await process.exitCode, 7);
      expect(await process.stdoutLines.toList(), ['hello']);
      expect(await process.stderrLines.toList(), ['problem']);
    },
  );
  test('timeout terminates subprocess and reports failure', () async {
    final bridge = DockerContainerBridge(executable: '/bin/sleep');
    final result = await bridge.cliRun([
      '10',
    ], timeout: const Duration(milliseconds: 30));
    expect(result.timedOut, isTrue);
    expect(result.ok, isFalse);
  });
  test('binary selection persists custom executable and missing binary fails clearly', () async {
    final bridge = DockerContainerBridge();
    expect(await bridge.locateBinary(customPath: '/bin/echo'), '/bin/echo');
    expect((await bridge.cliRun(['a b'])).stdout.trim(), 'a b');
  });
  test('Docker SI and binary size units', () {
    expect(DockerContainerBridge.parseSize('1.5GiB'), 1610612736);
    expect(DockerContainerBridge.parseSize('1.5GB'), 1500000000);
    expect(DockerContainerBridge.parseSize('N/A'), isNull);
  });
  test(
    'exec preserves exact bytes and independent nonzero exit streams',
    () async {
      final bridge = DockerContainerBridge(
        processStarter: (_) => Process.start('/bin/sh', [
          '-c',
          'printf out; printf err >&2; exit 7',
        ]),
      );
      final result = await bridge.containerExec(
        id: 'fixture',
        command: ['ignored'],
      );
      expect(result.stdout, 'out');
      expect(result.stderr, 'err');
      expect(result.exitCode, 7);
    },
  );
  test('exec bounds capture while draining the entire subprocess', () async {
    final bridge = DockerContainerBridge(
      processStarter: (_) =>
          Process.start('/usr/bin/printf', ['%s', 'x' * 70000]),
    );
    final result = await bridge.containerExec(
      id: 'fixture',
      command: ['ignored'],
    );
    expect(result.stdout, 'x' * 65536);
    expect(result.stdoutTruncated, isTrue);
    expect(result.exitCode, 0);
  });
  test('exec timeout remains failure and terminates its client', () async {
    final bridge = DockerContainerBridge(
      processStarter: (_) => Process.start('/bin/sleep', ['10']),
    );
    final result = await bridge.containerExec(
      id: 'fixture',
      command: ['ignored'],
      timeoutSeconds: 1,
    );
    expect(result.timedOut, isTrue);
    expect(result.exitCode, isNot(0));
  });
  test('pull forwards platform and reports inspected image identity', () async {
    final commands = <List<String>>[];
    final bridge = DockerContainerBridge(
      processStarter: (args) {
        commands.add(args);
        return Process.start('/usr/bin/printf', ['%s', 'Downloaded']);
      },
      runner: (args, _) async => BridgeCommandResult(
        exitCode: 0,
        stdout: jsonEncode([
          {
            'Id': 'sha256:abc',
            'Size': 123,
            'Os': 'linux',
            'Architecture': 'arm64',
          },
        ]),
        stderr: '',
      ),
    );
    final result = await bridge.imagePull(
      pullId: 'pull',
      reference: 'app:v1',
      platform: 'linux/arm64',
    );
    expect(commands.single, [
      'image',
      'pull',
      '--platform',
      'linux/arm64',
      'app:v1',
    ]);
    expect(result['digest'], 'sha256:abc');
    expect(result['reference'], 'app:v1');
  });
  test(
    'pull cancellation resolves as cancelled and releases the client',
    () async {
      final bridge = DockerContainerBridge(
        processStarter: (_) => Process.start('/bin/sleep', ['10']),
      );
      final pending = bridge.imagePull(pullId: 'cancel', reference: 'app:v1');
      await bridge.imagePullCancel('cancel');
      expect(
        (await pending.timeout(const Duration(seconds: 3)))['cancelled'],
        isTrue,
      );
    },
  );
  test(
    'failed pull preserves raw diagnostic rather than returning success',
    () async {
      final bridge = DockerContainerBridge(
        processStarter: (_) =>
            Process.start('/bin/sh', ['-c', 'printf unavailable >&2; exit 3']),
      );
      await expectLater(
        bridge.imagePull(pullId: 'fail', reference: 'app:v1'),
        throwsA(
          isA<BridgeCallException>().having(
            (e) => e.message,
            'message',
            contains('unavailable'),
          ),
        ),
      );
    },
  );
  test(
    'stopped containers retain configured ports and complete Docker inspection',
    () {
      final raw = <String, Object?>{
        'Id': '123',
        'Name': '/stopped',
        'State': {'Status': 'created'},
        'Config': {'Image': 'app:v1'},
        'HostConfig': {
          'PortBindings': {
            '80/tcp': [
              {'HostIp': '127.0.0.1', 'HostPort': '8080'},
            ],
          },
        },
        'NetworkSettings': {'Ports': {}},
      };
      final snapshot = ContainerSnapshotInfo.fromMap(
        DockerContainerBridge.normalizeContainer(raw),
      );
      expect(snapshot.publishedPorts.single.hostPort, 8080);
      expect(snapshot.rawConfiguration['docker'], raw);
    },
  );
}
