import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/project_service.dart';
import 'package:ghost_container_manager/services/registry_service.dart';

Map<String, Object?> registrySnapshot({
  String state = 'running',
  int port = 5056,
}) => <String, Object?>{
  'configuration': <String, Object?>{
    'id': 'gcm-registry',
    'image': <String, Object?>{'reference': 'registry:2'},
    'labels': <String, String>{},
    'creationDate': '2026-10-24T08:00:00Z',
    'stopSignal': 'SIGTERM',
    'initProcess': <String, Object?>{
      'executable': '/registry',
      'arguments': <String>[],
      'environment': <String>[],
    },
    'publishedPorts': <Object?>[
      <String, Object?>{
        'hostAddress': '127.0.0.1',
        'hostPort': port,
        'containerPort': 5000,
        'proto': 'tcp',
      },
    ],
  },
  'status': state,
  'networks': <Object?>[],
  'startedDate': state == 'running' ? '2026-10-24T08:00:01Z' : null,
};

class FakeProjectCli implements ProjectCli {
  final List<List<String>> runCalls = <List<String>>[];
  Future<BridgeCommandResult> Function(List<String> args)? onRun;

  @override
  Future<BridgeCommandResult> run(
    List<String> args, {
    Duration? timeout,
  }) async {
    runCalls.add(List<String>.of(args));
    if (onRun case final handler?) return handler(args);
    return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  ProjectCliProcess start(List<String> args) =>
      throw UnimplementedError('registry tests do not start a streaming CLI');
}

void main() {
  late Directory temp;
  late FakeContainerBridge bridge;
  late ContainerService containers;
  late ImageService images;
  late FakeProjectCli cli;
  late RegistryService registry;
  late List<RegistryProgress> progress;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gcm-registry-test-');
    bridge = FakeContainerBridge();
    containers = ContainerService(bridge: bridge);
    images = ImageService(bridge: bridge, containerService: containers);
    cli = FakeProjectCli();
    progress = <RegistryProgress>[];
    registry = RegistryService(
      containers: containers,
      images: images,
      cli: cli,
      dataDirectory: temp.path,
      probe: (_) async => true,
    );
  });

  tearDown(() async {
    containers.stopPolling();
    await containers.dispose();
    await bridge.pullEventsController.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test(
    'start pulls and creates a missing loopback registry with a bind',
    () async {
      cli.onRun = (args) async {
        expect(args.first, 'run');
        bridge.containers = <Map<String, Object?>>[registrySnapshot()];
        return const BridgeCommandResult(
          exitCode: 0,
          stdout: 'gcm-registry\n',
          stderr: '',
        );
      };

      final result = await registry.start(onProgress: progress.add);

      expect(result.running, isTrue);
      expect(result.port, 5056);
      expect(result.containerId, 'gcm-registry');
      expect(bridge.pullCalls.single, endsWith('registry:2 -'));
      expect(cli.runCalls, hasLength(1));
      final args = cli.runCalls.single;
      expect(
        args,
        containsAllInOrder(<String>[
          'run',
          '--detach',
          '--name',
          'gcm-registry',
          '--publish',
          '127.0.0.1:5056:5000',
          '--mount',
          'type=bind,source=${temp.path},target=/var/lib/registry',
          'registry:2',
        ]),
      );
      expect(Directory(temp.path).existsSync(), isTrue);
      expect(
        progress.map((event) => event.message),
        contains('registry container created'),
      );
    },
  );

  test(
    'existing registry starts once and running start is idempotent',
    () async {
      bridge.containers = <Map<String, Object?>>[
        registrySnapshot(state: 'stopped'),
      ];

      final started = await registry.start();
      final running = await registry.start();

      expect(started.running, isTrue);
      expect(running.running, isTrue);
      expect(bridge.startCalls, 1);
      expect(bridge.pullCalls, isEmpty);
      expect(cli.runCalls, isEmpty);
    },
  );

  test(
    'status combines the actual container, health, and data bytes',
    () async {
      bridge.containers = <Map<String, Object?>>[registrySnapshot(port: 5057)];
      File('${temp.path}/data.bin').writeAsBytesSync(List<int>.filled(12, 1));
      registry = RegistryService(
        containers: containers,
        images: images,
        cli: cli,
        dataDirectory: temp.path,
        probe: (port) async {
          expect(port, 5057);
          return false;
        },
      );

      final result = await registry.status();

      expect(result.running, isFalse);
      expect(result.port, 5057);
      expect(result.containerId, 'gcm-registry');
      expect(result.diskBytes, 12);
    },
  );

  test('stop retains the registry container and its data', () async {
    bridge.containers = <Map<String, Object?>>[registrySnapshot()];
    final data = File('${temp.path}/data.bin')..writeAsStringSync('keep');

    await registry.stop();
    final stopped = await containers.inspect('gcm-registry');

    expect(stopped.state.wireName, 'stopped');
    expect(data.readAsStringSync(), 'keep');
    expect(cli.runCalls, isEmpty);
    expect(
      bridge.calls.where((call) => call.startsWith('containerDelete')),
      isEmpty,
    );
  });

  test('pull progress is visible and cancellation prevents creation', () async {
    bridge.pullHangs = true;
    final cancellation = StreamController<void>();
    final future = registry.start(
      cancellation: cancellation.stream,
      onProgress: progress.add,
    );
    while (bridge.pullCalls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final pullId = bridge.pullCalls.single.split(' ').first;
    bridge.pullEventsController.add(
      BridgeImagePullEvent(
        pullId: pullId,
        description: 'Downloading registry',
        completedBytes: 50,
        totalBytes: 100,
      ),
    );
    while (progress.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }

    cancellation.add(null);
    await cancellation.close();
    await expectLater(
      future,
      throwsA(
        isA<GcmException>().having(
          (error) => error.message,
          'message',
          contains('取消'),
        ),
      ),
    );

    expect(progress.single.message, 'Downloading registry');
    expect(progress.single.fraction, 0.5);
    expect(bridge.pullCancelCalls, <String>[pullId]);
    expect(cli.runCalls, isEmpty);
    expect(bridge.containers, isEmpty);
  });
}
