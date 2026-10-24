import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/project_build_log_store.dart';
import 'package:ghost_container_manager/services/project_service.dart';

import 'container_service_test.dart' show snapshotPayload;

class FakeProjectCliProcess implements ProjectCliProcess {
  final stdout = StreamController<String>();
  final stderr = StreamController<String>();
  final exit = Completer<int>();
  int terminateCalls = 0;

  @override
  Stream<String> get stdoutLines => stdout.stream;

  @override
  Stream<String> get stderrLines => stderr.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  void terminate() {
    terminateCalls += 1;
  }

  Future<void> finish(int code) async {
    if (!exit.isCompleted) exit.complete(code);
    await stdout.close();
    await stderr.close();
  }
}

class FakeProjectCli implements ProjectCli {
  final runs = <List<String>>[];
  final starts = <List<String>>[];
  final runResults = <String, List<BridgeCommandResult>>{};
  Future<BridgeCommandResult> Function(List<String> args)? onRun;
  ProjectCliProcess Function(List<String> args)? onStart;

  @override
  Future<BridgeCommandResult> run(
    List<String> args, {
    Duration? timeout,
  }) async {
    runs.add(List<String>.unmodifiable(args));
    final handler = onRun;
    if (handler != null) return handler(args);
    final queue = runResults[args.join(' ')];
    if (queue != null && queue.isNotEmpty) return queue.removeAt(0);
    return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  ProjectCliProcess start(List<String> args) {
    starts.add(List<String>.unmodifiable(args));
    final factory = onStart;
    if (factory == null) throw StateError('Unexpected start: $args');
    return factory(args);
  }
}

class _FakeProjectBuildLogStore implements ProjectBuildLogStore {
  int writes = 0;
  String? project;
  String? imageName;
  String? dockerfile;
  String? stage;
  String? reason;
  String? logTail;
  Object? error;

  @override
  Future<String> write({
    required String project,
    required String imageName,
    required String dockerfile,
    required String stage,
    required String reason,
    required String logTail,
  }) async {
    writes += 1;
    this.project = project;
    this.imageName = imageName;
    this.dockerfile = dockerfile;
    this.stage = stage;
    this.reason = reason;
    this.logTail = logTail;
    final error = this.error;
    if (error != null) throw error;
    return 'memory-log';
  }

  @override
  Future<String?> readLatest({
    required String project,
    required String imageName,
  }) async {
    return null;
  }
}

void addImage(
  FakeContainerBridge bridge,
  String reference, {
  String? project,
  int sizeBytes = 100,
}) {
  bridge.images.add(<String, Object?>{
    'reference': reference,
    'digest': 'sha256:${reference.hashCode.abs()}',
    'sizeBytes': sizeBytes,
    'createdAt': '2026-10-24T00:00:00Z',
  });
  bridge.imageInspectResponses[reference] = <String, Object?>{
    'reference': reference,
    'sizeBytes': sizeBytes,
    'config': <String, Object?>{
      'labels': <String, String>{'com.ghost233.project': ?project},
    },
  };
}

BridgeCommandResult diskUsageResult(int bytes) => BridgeCommandResult(
  exitCode: 0,
  stdout: jsonEncode(<Object?>[
    <String, Object?>{'type': 'images', 'size': bytes},
  ]),
  stderr: '',
);

Future<String> writeDockerfile(Directory root) async {
  final file = File('${root.path}/Dockerfile');
  await file.writeAsString('FROM scratch\n');
  return file.path;
}

void main() {
  late Directory temp;
  late FakeContainerBridge bridge;
  late FakeProjectCli cli;
  late ContainerService containers;
  late ProjectService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gcm-project-service-');
    bridge = FakeContainerBridge();
    cli = FakeProjectCli();
    containers = ContainerService(bridge: bridge);
    service = ProjectService(
      cli: cli,
      containerService: containers,
      imageService: ImageService(bridge: bridge, containerService: containers),
      projectPaths: [temp.path],
      buildLogDirectory: '${temp.path}/build-logs',
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('init writes prefix-only toml and rejects an existing file', () async {
    final path = '${temp.path}/myapp';
    final result = await service.initProject(path: path);

    expect(result.prefix, 'myapp');
    expect(result.path, path);
    expect(
      await File('$path/ghostcontainer.toml').readAsString(),
      'prefix = "myapp"\n',
    );
    expect(
      () => service.initProject(path: path),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.conflict,
        ),
      ),
    );
  });

  test('init validates explicit and directory-derived prefixes', () async {
    expect(
      () => service.initProject(path: '${temp.path}/Bad_Name'),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.invalidArgument,
        ),
      ),
    );
    expect(
      () => service.initProject(
        path: '${temp.path}/valid',
        prefix: 'contains space',
      ),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.invalidArgument,
        ),
      ),
    );
  });

  test(
    'list merges toml, labels and prefix fallback with label authority',
    () async {
      final projectDir = Directory('${temp.path}/myapp')..createSync();
      await File('${projectDir.path}/ghostcontainer.toml')
          .writeAsString('prefix = "myapp"\n');
      final blogDir = Directory('${temp.path}/blog')..createSync();
      await File('${blogDir.path}/ghostcontainer.toml')
          .writeAsString('prefix = "blog"\n');

      bridge.containers = [
        snapshotPayload(
          id: 'web',
          image: 'myapp-go:latest',
          labels: const {'com.ghost233.project': 'myapp'},
        ),
      ];
      addImage(bridge, 'myapp-go:latest', project: 'myapp');
      addImage(bridge, 'myapp-db:latest', project: 'myapp');
      // The reference prefix is deliberately wrong: the label is authoritative.
      addImage(bridge, 'wrong-worker:latest', project: 'myapp');
      addImage(bridge, 'demo-api:latest'); // restore fallback: no label
      addImage(bridge, 'other-api:latest', project: 'other');

      final projects = await service.listProjects();
      final byName = {for (final p in projects) p.project: p};

      expect(byName.keys, containsAll(['myapp', 'blog', 'demo', 'other']));
      expect(byName['myapp']?.path, projectDir.path);
      expect(byName['myapp']?.containers, 1);
      expect(
        byName['myapp']?.images,
        containsAll([
          'myapp-go:latest',
          'myapp-db:latest',
          'wrong-worker:latest',
        ]),
      );
      expect(byName['myapp']?.images, isNot(contains('demo-api:latest')));
      expect(byName['demo']?.images, ['demo-api:latest']);
      expect(byName['blog']?.images, isEmpty);
    },
  );

  test('list reports the latest in-memory build completion time', () async {
    var now = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final clockService = ProjectService(
      cli: cli,
      containerService: containers,
      imageService: ImageService(bridge: bridge, containerService: containers),
      projectPaths: [temp.path],
      buildLogStore: _FakeProjectBuildLogStore(),
      clock: () => now,
    );
    final projectDir = Directory('${temp.path}/myapp')..createSync();
    await File('${projectDir.path}/ghostcontainer.toml')
        .writeAsString('prefix = "myapp"\n');
    final dockerfile = await writeDockerfile(projectDir);
    var exitCode = 0;
    cli.onStart = (_) {
      final process = FakeProjectCliProcess();
      unawaited(process.finish(exitCode));
      return process;
    };

    await clockService.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: projectDir.path,
    );
    expect((await clockService.listProjects()).single.lastBuildAt, now);

    now = now.add(const Duration(minutes: 1));
    exitCode = 1;
    final failed = await clockService.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: projectDir.path,
    );
    expect(failed.exitCode, 1);
    final summary = (await clockService.listProjects()).single;
    expect(summary.lastBuildAt, now);
    expect(summary.toJson()['lastBuildAt'], now.toIso8601String());
  });

  test('get resolves path through toml and reports image use', () async {
    final projectDir = Directory('${temp.path}/myapp')..createSync();
    await File('${projectDir.path}/ghostcontainer.toml')
        .writeAsString('prefix = "myapp"\n');
    bridge.containers = [
      snapshotPayload(
        id: 'web',
        image: 'myapp-go:latest',
        status: 'stopped',
        labels: const {'com.ghost233.project': 'myapp'},
      ),
    ];
    addImage(bridge, 'myapp-go:latest', project: 'myapp', sizeBytes: 4096);
    addImage(bridge, 'myapp-db:latest', project: 'myapp');

    final detail = await service.getProject(path: projectDir.path);

    expect(detail.project, 'myapp');
    expect(detail.path, projectDir.path);
    expect(detail.containers.map((c) => c.id), ['web']);
    final go = detail.images.singleWhere(
      (image) => image.reference == 'myapp-go:latest',
    );
    expect(go.inUse, isTrue);
    expect(go.sizeBytes, 4096);
    final db = detail.images.singleWhere(
      (image) => image.reference == 'myapp-db:latest',
    );
    expect(db.inUse, isFalse);
  });

  test(
    'get marks only images with a matching registry tag as pushed',
    () async {
      addImage(bridge, 'myapp-go1:latest', project: 'myapp');
      addImage(bridge, 'myapp-go10:latest', project: 'myapp');
      addImage(bridge, 'myapp-db:latest', project: 'myapp');
      addImage(bridge, '127.0.0.1:5056/myapp-go1:v1');

      final detail = await service.getProject(project: 'myapp');
      final byReference = <String, ProjectImageStatus>{
        for (final image in detail.images) image.reference: image,
      };

      final pushed = byReference['myapp-go1:latest']!;
      expect(pushed.pushedToRegistry, isTrue);
      expect(pushed.toJson()['pushed'], isTrue);
      expect(byReference['myapp-go10:latest']!.pushedToRegistry, isFalse);
      expect(byReference['myapp-db:latest']!.pushedToRegistry, isFalse);
    },
  );

  test('project inventory skips digest-addressed external images', () async {
    addImage(bridge, 'myapp-go1:latest', project: 'myapp');
    final digest = 'sha256:${List<String>.filled(64, 'a').join()}';
    bridge.images.addAll(<Map<String, Object?>>[
      <String, Object?>{
        'reference': '127.0.0.1:15000/foo@$digest',
        'digest': digest,
        'sizeBytes': 100,
      },
      <String, Object?>{
        'reference': digest,
        'digest': digest,
        'sizeBytes': 100,
      },
    ]);

    final projects = await service.listProjects();
    expect(projects.single.project, 'myapp');
    expect(projects.single.images, ['myapp-go1:latest']);

    final detail = await service.getProject(project: 'myapp');
    expect(detail.images.map((image) => image.reference), ['myapp-go1:latest']);
  });

  test('get rejects missing projects and invalid toml', () async {
    expect(
      () => service.getProject(project: 'missing'),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.notFound,
        ),
      ),
    );
    final bad = Directory('${temp.path}/bad')..createSync();
    await File('${bad.path}/ghostcontainer.toml')
        .writeAsString('[project]\nname = "wrong"\n');
    expect(
      () => service.getProject(path: bad.path),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.invalidArgument,
        ),
      ),
    );
  });

  test('build uses the fixed image name, CLI flags and progress', () async {
    final projectDir = Directory('${temp.path}/myapp')..createSync();
    await File('${projectDir.path}/ghostcontainer.toml')
        .writeAsString('prefix = "myapp"\n');
    await File('${projectDir.path}/Dockerfile').writeAsString('FROM scratch\n');
    final process = FakeProjectCliProcess();
    cli.onStart = (args) {
      expect(args, <String>[
        'build',
        '-t',
        'myapp-go1:latest',
        '--label',
        'com.ghost233.project=myapp',
        '-f',
        '${projectDir.path}/Dockerfile',
        '--build-arg',
        'A=1',
        '--build-arg',
        'B=two',
        '--no-cache',
        '--progress',
        'plain',
        projectDir.path,
      ]);
      return process;
    };
    process.stdout.add('#1 building');
    unawaited(process.finish(0));
    final progress = <String>[];

    final result = await service.buildProject(
      path: projectDir.path,
      name: 'go1',
      buildArgs: const {'B': 'two', 'A': '1'},
      noCache: true,
      onProgress: progress.add,
    );

    expect(result.project, 'myapp');
    expect(result.image, 'myapp-go1:latest');
    expect(result.exitCode, 0);
    expect(result.testsPassed, isNull);
    expect(result.output, isNull);
    expect(result.durationMs, greaterThanOrEqualTo(0));
    expect(progress, ['#1 building']);
    expect(result.failureLogPath, isNull);
    expect(await Directory('${temp.path}/build-logs').exists(), isFalse);
  });

  test('test requires a command and returns nonzero exit as data', () async {
    final process = FakeProjectCliProcess();
    cli.onStart = (args) {
      expect(args, <String>[
        'run',
        '--rm',
        '--label',
        'com.ghost233.project=myapp',
        '--label',
        'com.ghost233.role=test',
        'myapp-go1:latest',
        'sh',
        '-c',
        'exit 7',
      ]);
      return process;
    };
    process.stdout.add('ok');
    process.stderr.add('bad');
    unawaited(process.finish(7));

    final result = await service.testProject(
      project: 'myapp',
      name: 'go1',
      command: const ['sh', '-c', 'exit 7'],
    );

    expect(result.exitCode, 7);
    expect(result.testsPassed, isFalse);
    expect(result.stdout, 'ok\n');
    expect(result.stderr, 'bad\n');
    expect(result.truncated, isFalse);
    expect(
      () => service.testProject(project: 'myapp', name: 'go1', command: []),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.invalidArgument,
        ),
      ),
    );
  });

  test(
    'build throttles progress to 100ms and flushes the final line',
    () async {
      final dockerfile = await writeDockerfile(temp);
      final process = FakeProjectCliProcess();
      final started = Completer<void>();
      cli.onStart = (_) {
        started.complete();
        return process;
      };
      final progress = <String>[];
      final running = service.buildProject(
        project: 'myapp',
        name: 'go1',
        dockerfile: dockerfile,
        context: temp.path,
        onProgress: progress.add,
      );
      await started.future;

      process.stdout.add('#1');
      await Future<void>.delayed(Duration.zero);
      process.stdout.add('#2');
      process.stdout.add('#3');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(progress, ['#1', '#3']);

      process.stdout.add('#4');
      await Future<void>.delayed(Duration.zero);
      await process.finish(0);
      await running;
      expect(progress, ['#1', '#3', '#4']);
    },
  );

  test('build flushes pending progress when the output stream fails', () async {
    final dockerfile = await writeDockerfile(temp);
    final process = FakeProjectCliProcess();
    final started = Completer<void>();
    cli.onStart = (_) {
      started.complete();
      return process;
    };
    final progress = <String>[];
    final running = service.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: temp.path,
      onProgress: progress.add,
    );
    await started.future;

    process.stdout.add('#1');
    await Future<void>.delayed(Duration.zero);
    process.stdout.add('#2');
    await Future<void>.delayed(Duration.zero);
    final expectation = expectLater(
      running,
      throwsA(
        isA<GcmException>()
            .having((e) => e.code, 'code', GcmErrorCode.internal)
            .having((e) => e.message, 'message', contains('stream failed')),
      ),
    );
    process.stdout.addError(StateError('stream failed'));
    await process.finish(0);
    await expectation;

    expect(progress, ['#1', '#2']);
  });

  test(
    'build rejects a missing project path instead of using the CWD',
    () async {
      final process = FakeProjectCliProcess();
      cli.onStart = (_) => process;
      unawaited(process.finish(0));

      await expectLater(
        service.buildProject(project: 'myapp', name: 'go1'),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.invalidArgument)
              .having((e) => e.hint, 'hint', contains('path')),
        ),
      );
      expect(cli.starts, isEmpty);
    },
  );

  test('failed build returns exit code and writes only bounded logs', () async {
    final dockerfile = await writeDockerfile(temp);
    final process = FakeProjectCliProcess();
    cli.onStart = (_) => process;
    for (var i = 1; i <= 1100; i += 1) {
      process.stdout.add('line$i');
    }
    unawaited(process.finish(2));

    final result = await service.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: temp.path,
    );

    expect(result.exitCode, 2);
    expect(result.output, contains('line1100'));
    expect(result.output, isNot(contains('line1\n')));
    expect(result.failureLogPath, isNotNull);
    final log = await File(result.failureLogPath!).readAsString();
    expect(log, contains('project: myapp'));
    expect(log, contains('name: go1'));
    expect(log, contains('stage: build'));
    expect(log, contains('reason: exit code 2'));
    expect(log, contains('line1100'));
    expect(log, isNot(contains('line1\n')));
  });

  test(
    'build writes bounded failure logs through the injected store',
    () async {
      final dockerfile = await writeDockerfile(temp);
      final store = _FakeProjectBuildLogStore();
      service = ProjectService(
        cli: cli,
        containerService: containers,
        imageService: ImageService(
          bridge: bridge,
          containerService: containers,
        ),
        projectPaths: [temp.path],
        buildLogDirectory: '${temp.path}/build-logs',
        buildLogStore: store,
      );
      final process = FakeProjectCliProcess();
      cli.onStart = (_) => process;
      for (var i = 1; i <= 1005; i += 1) {
        process.stdout.add('line$i');
      }
      unawaited(process.finish(2));

      final result = await service.buildProject(
        project: 'myapp',
        name: 'go1',
        dockerfile: dockerfile,
        context: temp.path,
      );

      expect(result.exitCode, 2);
      expect(store.writes, 1);
      expect(store.project, 'myapp');
      expect(store.imageName, 'go1');
      expect(store.dockerfile, dockerfile);
      expect(store.stage, 'build');
      expect(store.reason, 'exit code 2');
      expect(
        store.logTail,
        '${List.generate(1000, (i) => 'line${i + 6}').join('\n')}\n',
      );
      expect(result.failureLogPath, 'memory-log');
      expect(await Directory('${temp.path}/build-logs').exists(), isFalse);
    },
  );

  test('build preserves the failed result when the log store throws', () async {
    final dockerfile = await writeDockerfile(temp);
    final store = _FakeProjectBuildLogStore()..error = StateError('disk full');
    service = ProjectService(
      cli: cli,
      containerService: containers,
      imageService: ImageService(bridge: bridge, containerService: containers),
      projectPaths: [temp.path],
      buildLogDirectory: '${temp.path}/build-logs',
      buildLogStore: store,
    );
    final process = FakeProjectCliProcess();
    cli.onStart = (_) => process;
    process.stdout.add('compiler failed');
    unawaited(process.finish(2));

    final result = await service.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: temp.path,
    );

    expect(result.exitCode, 2);
    expect(result.output, 'compiler failed\n');
    expect(result.failureLogPath, isNull);
    expect(store.writes, 1);
  });

  test('build runs tests only when an explicit command is supplied', () async {
    final dockerfile = await writeDockerfile(temp);
    final build = FakeProjectCliProcess();
    final testRun = FakeProjectCliProcess();
    cli.onStart = (args) {
      if (args.first == 'build') return build;
      expect(args.sublist(args.length - 3), ['go', 'test', './...']);
      return testRun;
    };
    build.stdout.add('#build');
    unawaited(build.finish(0));
    testRun.stderr.add('failed');
    unawaited(testRun.finish(1));
    final progress = <String>[];

    final result = await service.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: temp.path,
      skipTests: false,
      testCommand: const ['go', 'test', './...'],
      onProgress: progress.add,
    );

    expect(result.exitCode, 0);
    expect(result.testsPassed, isFalse);
    expect(result.output, contains('failed'));
    expect(result.failureLogPath, isNotNull);
    expect(cli.starts, hasLength(2));
    expect(progress, ['#build']);
    expect(
      await File(result.failureLogPath!).readAsString(),
      contains('stage: test'),
    );
  });

  test('build rejects requested tests without an explicit command', () async {
    final process = FakeProjectCliProcess();
    cli.onStart = (_) => process;
    unawaited(process.finish(0));

    await expectLater(
      service.buildProject(project: 'myapp', name: 'go1', skipTests: false),
      throwsA(
        isA<GcmException>()
            .having((e) => e.code, 'code', GcmErrorCode.invalidArgument)
            .having((e) => e.message, 'message', contains('testCommand')),
      ),
    );
    expect(cli.starts, isEmpty);
  });

  test('same project work conflicts while another project can run', () async {
    final dockerfile = await writeDockerfile(temp);
    final first = FakeProjectCliProcess();
    final other = FakeProjectCliProcess();
    cli.onStart = (args) => args.contains('myapp-go1:latest') ? first : other;
    final running = service.buildProject(
      project: 'myapp',
      name: 'go1',
      dockerfile: dockerfile,
      context: temp.path,
    );
    while (cli.starts.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }

    await expectLater(
      service.buildProject(
        project: 'myapp',
        name: 'go2',
        dockerfile: dockerfile,
        context: temp.path,
      ),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.conflict,
        ),
      ),
    );
    final otherRun = service.buildProject(
      project: 'other',
      name: 'go2',
      dockerfile: dockerfile,
      context: temp.path,
    );
    while (cli.starts.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    await other.finish(0);
    await first.finish(0);
    expect((await otherRun).exitCode, 0);
    expect((await running).exitCode, 0);
  });

  test(
    'build cancellation terminates the CLI and records one failure',
    () async {
      final dockerfile = await writeDockerfile(temp);
      final process = FakeProjectCliProcess();
      final cancellation = StreamController<void>();
      cli.onStart = (_) => process;
      final running = service.buildProject(
        project: 'myapp',
        name: 'go1',
        dockerfile: dockerfile,
        context: temp.path,
        cancellation: cancellation.stream,
      );
      while (cli.starts.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      cancellation.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(process.terminateCalls, 1);
      await process.finish(130);

      await expectLater(
        running,
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.internal,
          ),
        ),
      );
      await cancellation.close();
      final logs = await Directory('${temp.path}/build-logs')
          .list()
          .where((entity) => entity is File)
          .toList();
      expect(logs, hasLength(1));
      expect(await File(logs.single.path).readAsString(), contains('项目构建已取消'));
    },
  );

  test('test captures at most 64 KiB and marks truncation', () async {
    final process = FakeProjectCliProcess();
    cli.onStart = (_) => process;
    process.stdout.add('a' * (64 * 1024 + 10));
    process.stderr.add('err');
    unawaited(process.finish(0));

    final result = await service.testProject(
      project: 'myapp',
      name: 'go1',
      command: const ['true'],
    );

    expect(utf8.encode(result.stdout), hasLength(64 * 1024));
    expect(result.stderr, 'err\n');
    expect(result.truncated, isTrue);
  });

  test('oversized Dockerfile is rejected before starting the CLI', () async {
    final projectDir = Directory('${temp.path}/myapp')..createSync();
    await File('${projectDir.path}/ghostcontainer.toml')
        .writeAsString('prefix = "myapp"\n');
    await File('${projectDir.path}/Dockerfile')
        .writeAsString('a' * (16 * 1024 + 1));

    await expectLater(
      service.buildProject(path: projectDir.path, name: 'go1'),
      throwsA(
        isA<GcmException>().having(
          (e) => e.code,
          'code',
          GcmErrorCode.invalidArgument,
        ),
      ),
    );
    expect(cli.starts, isEmpty);
  });

  test(
    'build validates Dockerfiles for explicit context and dockerfile paths',
    () async {
      final process = FakeProjectCliProcess();
      cli.onStart = (_) => process;
      unawaited(process.finish(0));
      final context = Directory('${temp.path}/context')..createSync();
      final contextDockerfile = '${context.path}/Dockerfile';

      await expectLater(
        service.buildProject(
          project: 'myapp',
          name: 'go1',
          context: context.path,
        ),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.notFound)
              .having((e) => e.message, 'message', contains(contextDockerfile)),
        ),
      );

      final missingDockerfile = '${temp.path}/missing/Dockerfile';
      await expectLater(
        service.buildProject(
          project: 'myapp',
          name: 'go1',
          context: temp.path,
          dockerfile: missingDockerfile,
        ),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.notFound)
              .having((e) => e.message, 'message', contains(missingDockerfile)),
        ),
      );
      expect(cli.starts, isEmpty);
    },
  );

  test('file build log store sanitizes image name colons', () async {
    final store = FileProjectBuildLogStore(
      directory: '${temp.path}/sanitized-logs',
      clock: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    final path = await store.write(
      project: 'myapp',
      imageName: 'go1:latest',
      dockerfile: '/tmp/Dockerfile',
      stage: 'build',
      reason: 'exit code 1',
      logTail: 'failure',
    );

    expect(path, endsWith('-myapp-go1-latest.log'));
    expect(path, isNot(contains('go1:latest.log')));
    final content = await File(path).readAsString();
    expect(content, contains('name: go1:latest'));
    expect(content, contains('failure'));
  });

  test('service exposes latest matching build failure log history', () async {
    var now = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final store = FileProjectBuildLogStore(
      directory: '${temp.path}/history-logs',
      clock: () => now,
    );
    final historyService = ProjectService(
      cli: cli,
      containerService: containers,
      imageService: ImageService(bridge: bridge, containerService: containers),
      buildLogStore: store,
    );

    expect(
      await historyService.buildLogStore.readLatest(
        project: 'myapp',
        imageName: 'go1:latest',
      ),
      isNull,
    );
    await store.write(
      project: 'myapp',
      imageName: 'go1:latest',
      dockerfile: '/tmp/Dockerfile',
      stage: 'build',
      reason: 'older',
      logTail: 'old output',
    );
    now = now.add(const Duration(seconds: 1));
    await store.write(
      project: 'myapp',
      imageName: 'go2:latest',
      dockerfile: '/tmp/Dockerfile',
      stage: 'build',
      reason: 'other image',
      logTail: 'other output',
    );
    now = now.add(const Duration(seconds: 1));
    await store.write(
      project: 'myapp',
      imageName: 'go1:latest',
      dockerfile: '/tmp/Dockerfile',
      stage: 'build',
      reason: 'newest',
      logTail: 'new output',
    );

    final latest = await historyService.buildLogStore.readLatest(
      project: 'myapp',
      imageName: 'go1:latest',
    );
    expect(latest, contains('reason: newest'));
    expect(latest, contains('new output'));
    expect(latest, isNot(contains('old output')));
  });

  test('build failure logs retain only the newest twenty', () async {
    final dockerfile = await writeDockerfile(temp);
    cli.onStart = (_) {
      final process = FakeProjectCliProcess();
      process.stdout.add('failure');
      unawaited(process.finish(1));
      return process;
    };
    final paths = <String>[];
    for (var i = 0; i < 21; i += 1) {
      final result = await service.buildProject(
        project: 'myapp',
        name: 'go1',
        dockerfile: dockerfile,
        context: temp.path,
      );
      paths.add(result.failureLogPath!);
    }

    final logs = await Directory('${temp.path}/build-logs')
        .list()
        .where((entity) => entity is File)
        .toList();
    expect(logs, hasLength(20));
    expect(await File(paths.first).exists(), isFalse);
    expect(await File(paths.last).exists(), isTrue);
  });

  test(
    'publish tags, pushes over HTTP and optionally removes local tags',
    () async {
      addImage(bridge, 'myapp-go1:latest', project: 'myapp', sizeBytes: 4096);
      final push = FakeProjectCliProcess();
      cli.onStart = (args) {
        expect(args, <String>[
          'image',
          'push',
          '--scheme',
          'http',
          '127.0.0.1:5056/myapp-go1:latest',
        ]);
        return push;
      };
      push.stdout.add('pushed');
      unawaited(push.finish(0));
      final progress = <String>[];

      final result = await service.publishProject(
        project: 'myapp',
        name: 'go1',
        deleteLocal: true,
        onProgress: progress.add,
      );

      expect(result.project, 'myapp');
      expect(result.pushed.single.source, 'myapp-go1:latest');
      expect(result.pushed.single.target, '127.0.0.1:5056/myapp-go1:latest');
      expect(result.pushed.single.sizeBytes, 4096);
      expect(progress, ['pushed']);
      expect(cli.runs, <List<String>>[
        ['image', 'tag', 'myapp-go1:latest', '127.0.0.1:5056/myapp-go1:latest'],
        ['image', 'delete', '127.0.0.1:5056/myapp-go1:latest'],
        ['image', 'delete', 'myapp-go1:latest'],
      ]);
    },
  );

  test(
    'restore pulls over HTTP and tags back to the project reference',
    () async {
      final pull = FakeProjectCliProcess();
      cli.onStart = (args) {
        expect(args, <String>[
          'image',
          'pull',
          '--scheme',
          'http',
          '127.0.0.1:5056/myapp-go1:latest',
        ]);
        return pull;
      };
      unawaited(pull.finish(0));

      final result = await service.restoreProject(
        project: 'myapp',
        name: 'go1',
      );

      expect(result.project, 'myapp');
      expect(result.restored.single.reference, 'myapp-go1:latest');
      expect(cli.runs, <List<String>>[
        ['image', 'tag', '127.0.0.1:5056/myapp-go1:latest', 'myapp-go1:latest'],
      ]);
    },
  );

  test('publish maps a timed out CLI tag to TIMEOUT', () async {
    addImage(bridge, 'myapp-go1:latest', project: 'myapp');
    cli.onRun = (_) async => const BridgeCommandResult(
      exitCode: -1,
      stdout: '',
      stderr: 'deadline exceeded',
      timedOut: true,
    );

    await expectLater(
      service.publishProject(project: 'myapp', name: 'go1'),
      throwsA(
        isA<GcmException>()
            .having((e) => e.code, 'code', GcmErrorCode.timeout)
            .having((e) => e.source, 'source', 'cli')
            .having((e) => e.message, 'message', contains('超时')),
      ),
    );
    expect(cli.starts, isEmpty);
  });

  test(
    'publish push failure cleans only the target tag and preserves the error',
    () async {
      addImage(bridge, 'myapp-go1:latest', project: 'myapp');
      const target = '127.0.0.1:5056/myapp-go1:latest';
      final cleanup = Completer<BridgeCommandResult>();
      cli.onRun = (args) async {
        if (args case ['image', 'delete', target]) {
          return cleanup.future;
        }
        return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
      };
      final push = FakeProjectCliProcess();
      cli.onStart = (_) => push;
      push.stderr.add('denied');
      unawaited(push.finish(1));

      await expectLater(
        service
            .publishProject(project: 'myapp', name: 'go1', deleteLocal: true)
            .timeout(const Duration(seconds: 1)),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.internal)
              .having((e) => e.source, 'source', 'cli')
              .having((e) => e.message, 'message', contains('denied')),
        ),
      );
      expect(cli.runs, <List<String>>[
        ['image', 'tag', 'myapp-go1:latest', target],
        ['image', 'delete', target],
      ]);

      cleanup.completeError(StateError('cleanup failed'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'disk usage snapshot only reads df and returns null when unavailable',
    () async {
      final results = <BridgeCommandResult>[
        diskUsageResult(2048),
        const BridgeCommandResult(exitCode: 1, stdout: '', stderr: 'df failed'),
        const BridgeCommandResult(exitCode: 0, stdout: '[]', stderr: ''),
      ];
      cli.onRun = (args) async {
        expect(args, <String>['system', 'df', '--format', 'json']);
        return results.removeAt(0);
      };

      expect(await service.diskUsageBytes(), 2048);
      expect(await service.diskUsageBytes(), isNull);
      expect(await service.diskUsageBytes(), isNull);
      expect(results, isEmpty);
      expect(cli.runs, hasLength(3));
      expect(bridge.calls, isEmpty);
    },
  );

  test('reclaim reads container 1.5 sizeInBytes disk snapshots', () async {
    cli.onRun = (args) async {
      expect(args, <String>['system', 'df', '--format', 'json']);
      return BridgeCommandResult(
        exitCode: 0,
        stdout: jsonEncode(<String, Object?>{
          'containers': <String, Object?>{
            'active': 19,
            'reclaimable': 2,
            'sizeInBytes': 1000,
            'total': 21,
          },
          'images': <String, Object?>{
            'active': 4,
            'reclaimable': 1,
            'sizeInBytes': 2000,
            'total': 5,
          },
          'volumes': <String, Object?>{
            'active': 3,
            'reclaimable': 1,
            'sizeInBytes': 3000,
            'total': 4,
          },
        }),
        stderr: '',
      );
    };

    final report = await service.reclaimProject(project: 'myapp', dryRun: true);

    expect(report.disk.beforeBytes, 6000);
    expect(report.disk.afterBytes, 6000);
    expect(report.disk.reclaimedBytes, 0);
  });

  test(
    'reclaim deletes project containers then only unreferenced images',
    () async {
      bridge.containers = <Map<String, Object?>>[
        snapshotPayload(
          id: 'web',
          image: 'myapp-go1:latest',
          labels: const {'com.ghost233.project': 'myapp'},
        ),
        snapshotPayload(
          id: 'keep',
          image: 'myapp-go2:latest',
          status: 'stopped',
          labels: const {'com.ghost233.project': 'myapp'},
        ),
        snapshotPayload(
          id: 'external',
          image: 'myapp-db:latest',
          labels: const {'com.ghost233.project': 'other'},
        ),
      ];
      bridge.writeFailures['delete:keep'] = 'denied';
      addImage(bridge, 'myapp-go1:latest', project: 'myapp');
      addImage(bridge, 'myapp-go2:latest', project: 'myapp');
      addImage(bridge, 'myapp-db:latest', project: 'myapp');
      addImage(bridge, 'myapp-unused:latest', project: 'myapp');
      addImage(bridge, 'myapp-lookalike:latest');
      addImage(bridge, 'other-unused:latest', project: 'other');
      final deleted = <String>[];
      var diskReads = 0;
      cli.onRun = (args) async {
        if (args.join(' ') == 'system df --format json') {
          diskReads += 1;
          return diskUsageResult(diskReads == 1 ? 1000 : 400);
        }
        if (args case ['image', 'delete', final reference]) {
          deleted.add(reference);
          return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        throw StateError('Unexpected CLI: $args');
      };

      final report = await service.reclaimProject(project: 'myapp');

      expect(report.stoppedContainers, <String>['web']);
      expect(report.deletedContainers, <String>['web']);
      expect(report.failedContainers, <String>['keep']);
      expect(
        report.deletedImages,
        unorderedEquals(<String>['myapp-go1:latest', 'myapp-unused:latest']),
      );
      expect(report.retainedImages.single.reference, 'myapp-go2:latest');
      expect(report.retainedImages.single.reason, 'inUse.project');
      expect(report.skippedExternalImages.single.reference, 'myapp-db:latest');
      expect(report.skippedExternalImages.single.usedBy, <String>['external']);
      expect(deleted, isNot(contains('myapp-lookalike:latest')));
      expect(deleted, isNot(contains('other-unused:latest')));
      expect(report.disk.beforeBytes, 1000);
      expect(report.disk.afterBytes, 400);
      expect(report.disk.reclaimedBytes, 600);
      expect(report.errors.join('\n'), contains('denied'));
      expect(bridge.stopCalls, 1);
      expect(bridge.deleteCalls, 2);
      expect(diskReads, 2);
    },
  );

  test('dryRun returns the same report shape without any writes', () async {
    bridge.containers = <Map<String, Object?>>[
      snapshotPayload(
        id: 'web',
        image: 'myapp-go1:latest',
        labels: const {'com.ghost233.project': 'myapp'},
      ),
    ];
    addImage(bridge, 'myapp-go1:latest', project: 'myapp');
    addImage(bridge, 'myapp-unused:latest', project: 'myapp');
    cli.onRun = (args) async {
      expect(args, <String>['system', 'df', '--format', 'json']);
      return diskUsageResult(800);
    };

    final report = await service.reclaimProject(project: 'myapp', dryRun: true);

    expect(report.stoppedContainers, <String>['web']);
    expect(report.deletedContainers, <String>['web']);
    expect(report.failedContainers, isEmpty);
    expect(report.retainedImages.single.reference, 'myapp-go1:latest');
    expect(report.deletedImages, <String>['myapp-unused:latest']);
    expect(report.disk.beforeBytes, 800);
    expect(report.disk.afterBytes, 800);
    expect(report.disk.reclaimedBytes, 0);
    expect(report.errors, isEmpty);
    expect(bridge.stopCalls, 0);
    expect(bridge.deleteCalls, 0);
    expect(cli.runs.single, <String>['system', 'df', '--format', 'json']);
    expect(report.toJson().keys, <String>{
      'project',
      'containers',
      'images',
      'disk',
      'errors',
    });
  });

  test(
    'reclaim without force preserves running containers consistently',
    () async {
      bridge.containers = <Map<String, Object?>>[
        snapshotPayload(
          id: 'web',
          image: 'myapp-go1:latest',
          labels: const {'com.ghost233.project': 'myapp'},
        ),
      ];
      addImage(bridge, 'myapp-go1:latest', project: 'myapp');
      addImage(bridge, 'myapp-unused:latest', project: 'myapp');
      cli.onRun = (args) async {
        if (args.join(' ') == 'system df --format json') {
          return diskUsageResult(800);
        }
        if (args case ['image', 'delete', 'myapp-unused:latest']) {
          return const BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        throw StateError('Unexpected CLI: $args');
      };

      final preview = await service.reclaimProject(
        project: 'myapp',
        dryRun: true,
        force: false,
      );
      expect(preview.failedContainers, <String>['web']);
      expect(preview.stoppedContainers, isEmpty);
      expect(preview.deletedContainers, isEmpty);
      expect(preview.retainedImages.single.reference, 'myapp-go1:latest');
      expect(preview.deletedImages, <String>['myapp-unused:latest']);
      expect(preview.errors.join('\n'), contains('force=false'));

      final report = await service.reclaimProject(
        project: 'myapp',
        force: false,
      );
      expect(report.failedContainers, <String>['web']);
      expect(report.stoppedContainers, isEmpty);
      expect(report.deletedContainers, isEmpty);
      expect(report.retainedImages.single.reason, 'inUse.project');
      expect(report.deletedImages, <String>['myapp-unused:latest']);
      expect(report.errors.join('\n'), contains('is running'));
      expect(bridge.stopCalls, 0);
    },
  );
}
