import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/project_service.dart';

import 'project_service_test.dart' show FakeProjectCli;

void main() {
  test('重启发现待恢复意图并识别大小写不同的容器归属', () async {
    final root = await Directory.systemTemp.createTemp('gcm-discover-');
    addTearDown(() => root.delete(recursive: true));
    final a = await Directory('${root.path}/a').create();
    final b = await Directory('${root.path}/b').create();
    final storage = File('${root.path}/registry.json');
    final registry = DirectoryRegistry(storage);
    await registry.createIntent(
      operationId: 'z',
      directory: a.path,
      businessName: 'one',
      runtimeName: 'runtime-one',
    );
    await registry.createIntent(
      operationId: 'a',
      directory: a.path,
      businessName: 'two',
      runtimeName: 'runtime-two',
    );
    final id = 'a' * 64;
    await registry.register(a.path, 'CONTAINER:${id.toUpperCase()}');
    await expectLater(registry.registerContainer(b.path, id), throwsStateError);
    expect(
      () => registry.registerContainer(b.path, 'short'),
      throwsArgumentError,
    );
    final restarted = DirectoryRegistry(storage);
    expect(
      (await restarted.pendingIntents()).map((intent) => intent.operationId),
      ['a', 'z'],
    );
    await restarted.advanceIntent('a', CreationPhase.created, containerId: id);
    await restarted.advanceIntent(
      'a',
      CreationPhase.registered,
      containerId: id,
    );
    expect(
      (await DirectoryRegistry(
        storage,
      ).pendingIntents()).map((intent) => intent.operationId),
      ['z'],
    );
  });
  test('跨 isolate 恢复锁互斥', () async {
    final root = await Directory.systemTemp.createTemp('gcm-isolate-lock-');
    addTearDown(() => root.delete(recursive: true));
    final storage = '${root.path}/registry.json';
    final marker = '${root.path}/marker';
    final results = await Future.wait(
      List.generate(
        4,
        (_) => Isolate.run(() async {
          final registry = DirectoryRegistry(File(storage));
          return registry.withIntentLock('shared', () async {
            final file = File(marker);
            final overlap = await file.exists();
            await file.writeAsString('held');
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await file.delete();
            return overlap;
          });
        }),
      ),
    );
    expect(results, everyElement(isFalse));
  });
  test('跨进程恢复锁互斥', () async {
    final root = await Directory.systemTemp.createTemp('gcm-process-lock-');
    addTearDown(() => root.delete(recursive: true));
    var sdk = Platform.environment['GCM_FLUTTER_SDK'];
    if (sdk == null) {
      var directory = File(Platform.resolvedExecutable).parent;
      while (directory.parent.path != directory.path) {
        if (await File('${directory.path}/bin/dart').exists()) {
          sdk = directory.path;
          break;
        }
        directory = directory.parent;
      }
    }
    expect(sdk, isNotNull, reason: 'Flutter SDK must be discoverable');
    final args = [
      'run',
      'test/support/directory_registry_process.dart',
      '${root.path}/registry.json',
      '${root.path}/marker',
    ];
    final processes = await Future.wait(
      List.generate(4, (_) => Process.start('$sdk/bin/dart', args)),
    );
    for (final process in processes) {
      final errors = process.stderr.transform(systemEncoding.decoder).join();
      final status = await process.exitCode;
      expect(status, 0, reason: await errors);
    }
  });

  test('持久化写入失败保留已提交意图', () async {
    final root = await Directory.systemTemp.createTemp('gcm-write-failure-');
    addTearDown(() async {
      await Process.run('chmod', ['700', root.path]);
      await root.delete(recursive: true);
    });
    final work = await Directory('${root.path}/work').create();
    final registry = DirectoryRegistry(File('${root.path}/registry.json'));
    await registry.createIntent(
      operationId: 'op',
      directory: work.path,
      businessName: 'business',
      runtimeName: 'runtime',
    );
    expect((await Process.run('chmod', ['500', root.path])).exitCode, 0);
    await expectLater(
      registry.advanceIntent(
        'op',
        CreationPhase.created,
        containerId: 'a' * 64,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await registry.readIntent('op'))?.phase, CreationPhase.prepared);
  });
  test('创建意图重启恢复、幂等推进及唯一容器归属', () async {
    final root = await Directory.systemTemp.createTemp('gcm-intent-');
    addTearDown(() => root.delete(recursive: true));
    final work = await Directory('${root.path}/work').create();
    final other = await Directory('${root.path}/other').create();
    final alias = await Link('${root.path}/alias').create(work.path);
    final storage = File('${root.path}/registry.json');
    final id = 'a' * 64;
    final first = DirectoryRegistry(storage);
    final intent = await first.createIntent(
      operationId: 'op-1',
      directory: alias.path,
      businessName: 'business',
      runtimeName: 'runtime',
    );
    expect(intent.directory, await work.resolveSymbolicLinks());
    expect(intent.phase, CreationPhase.prepared);
    final restarted = DirectoryRegistry(storage);
    expect((await restarted.readIntent('op-1'))?.runtimeName, 'runtime');
    await restarted.advanceIntent(
      'op-1',
      CreationPhase.created,
      containerId: id,
    );
    await restarted.advanceIntent(
      'op-1',
      CreationPhase.registered,
      containerId: id,
    );
    await restarted.advanceIntent(
      'op-1',
      CreationPhase.registered,
      containerId: id,
    );
    expect(await restarted.query(work.path), ['container:$id']);
    await expectLater(
      restarted.register(other.path, 'container:$id'),
      throwsStateError,
    );
    await expectLater(
      restarted.advanceIntent(
        'op-1',
        CreationPhase.registered,
        containerId: 'b' * 64,
      ),
      throwsStateError,
    );
    await expectLater(
      restarted.createIntent(
        operationId: 'op-1',
        directory: other.path,
        businessName: 'business',
        runtimeName: 'runtime',
      ),
      throwsStateError,
    );
  });

  test('并发恢复和冲突登记序列化', () async {
    final root = await Directory.systemTemp.createTemp('gcm-intent-lock-');
    addTearDown(() => root.delete(recursive: true));
    final a = await Directory('${root.path}/a').create();
    final b = await Directory('${root.path}/b').create();
    final storage = File('${root.path}/registry.json');
    final first = DirectoryRegistry(storage);
    final second = DirectoryRegistry(storage);
    var running = 0;
    var maximum = 0;
    await Future.wait(
      List.generate(
        10,
        (index) =>
            (index.isEven ? first : second).withIntentLock('op', () async {
              running++;
              if (running > maximum) maximum = running;
              await Future<void>.delayed(const Duration(milliseconds: 2));
              running--;
            }),
      ),
    );
    expect(maximum, 1);
    final id = 'f' * 64;
    final results = await Future.wait(
      [a, b].map((directory) async {
        try {
          await DirectoryRegistry(storage)
              .register(directory.path, 'container:$id');
          return true;
        } on StateError {
          return false;
        }
      }),
    );
    expect(results.where((success) => success).length, 1);
  });

  test('损坏、错误类型及写入失败不会视为成功或空记录', () async {
    final root = await Directory.systemTemp.createTemp('gcm-intent-error-');
    addTearDown(() => root.delete(recursive: true));
    final work = await Directory('${root.path}/work').create();
    final storage = File('${root.path}/registry.json');
    final registry = DirectoryRegistry(storage);
    await storage.writeAsString('{broken');
    await expectLater(registry.query(work.path), throwsFormatException);
    await expectLater(
      registry.createIntent(
        operationId: 'op',
        directory: work.path,
        businessName: 'business',
        runtimeName: 'runtime',
      ),
      throwsFormatException,
    );
    expect(await storage.readAsString(), '{broken');
    await storage.delete();
    await Directory(storage.path).create();
    await expectLater(
      registry.query(work.path),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      registry.register(work.path, 'container:one'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('旧格式在写入意图后保留并可查询', () async {
    final root = await Directory.systemTemp.createTemp('gcm-intent-legacy-');
    addTearDown(() => root.delete(recursive: true));
    final work = await Directory('${root.path}/work').create();
    final storage = File('${root.path}/registry.json');
    await storage.writeAsString(
      '{"${await work.resolveSymbolicLinks()}":["container:old"]}',
    );
    final registry = DirectoryRegistry(storage);
    await registry.createIntent(
      operationId: 'legacy',
      directory: work.path,
      businessName: 'business',
      runtimeName: 'runtime',
    );
    expect(await DirectoryRegistry(storage).query(work.path), [
      'container:old',
    ]);
  });
  test('共享管理入口登记后在重建入口中可查询', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final directory = await Directory('${root.path}/work').create();
    final storage = File('${root.path}/registry.json');
    final bridge = FakeContainerBridge();
    final containers = ContainerService(bridge: bridge);
    addTearDown(containers.dispose);
    ProjectService createService() => ProjectService(
      cli: FakeProjectCli(),
      containerService: containers,
      imageService: ImageService(bridge: bridge, containerService: containers),
      directoryRegistry: DirectoryRegistry(storage),
    );
    final first = createService();
    expect(await first.directoryRegistry.query(directory.path), isEmpty);
    expect(await storage.exists(), isFalse);
    await first.directoryRegistry.register(directory.path, 'container:one');
    expect(await createService().directoryRegistry.query(directory.path), [
      'container:one',
    ]);
  });
  test('查询未登记管理目录为空且不创建登记', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final directory = await Directory('${root.path}/work').create();
    final storage = File('${root.path}/data/registry.json');
    final registry = DirectoryRegistry(storage);

    expect(await registry.query(directory.path), isEmpty);
    expect(await storage.exists(), isFalse);
  });

  test('显式登记关系在服务重建后持久可查询', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final directory = await Directory('${root.path}/work').create();
    final storage = File('${root.path}/data/registry.json');
    await DirectoryRegistry(storage).register(directory.path, 'container:one');

    expect(await DirectoryRegistry(storage).query(directory.path), [
      'container:one',
    ]);
  });

  test('符号链接归一而父子管理目录相互隔离', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final parent = await Directory('${root.path}/parent').create();
    final child = await Directory('${parent.path}/child').create();
    final alias = await Link('${root.path}/alias').create(parent.path);
    final bridge = FakeContainerBridge();
    final containers = ContainerService(bridge: bridge);
    addTearDown(containers.dispose);
    final service = ProjectService(
      cli: FakeProjectCli(),
      containerService: containers,
      imageService: ImageService(bridge: bridge, containerService: containers),
      directoryRegistry: DirectoryRegistry(File('${root.path}/registry.json')),
    );
    final registry = service.directoryRegistry;
    await registry.register(alias.path, 'container:parent');
    await registry.register(child.path, 'container:child');
    expect(await registry.query(parent.path), ['container:parent']);
    expect(await registry.query('${alias.path}/child'), ['container:child']);
  });

  test('只接受本地现存绝对目录', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File('${root.path}/file').writeAsString('x');
    final storage = File('${root.path}/registry.json');
    final registry = DirectoryRegistry(storage);
    for (final path in [
      'relative/path',
      'https://example.com/path',
      file.path,
      '${root.path}/missing',
    ]) {
      await expectLater(registry.query(path), throwsArgumentError);
      await expectLater(
        registry.register(path, 'container:one'),
        throwsArgumentError,
      );
    }
    expect(await storage.exists(), isFalse);
  });

  test('并发登记不会丢失关系', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final work = await Directory('${root.path}/work').create();
    final storage = File('${root.path}/registry.json');
    await Future.wait([
      DirectoryRegistry(storage).register(work.path, 'container:one'),
      DirectoryRegistry(storage).register(work.path, 'container:two'),
    ]);
    expect(
      await DirectoryRegistry(storage).query(work.path),
      unorderedEquals(['container:one', 'container:two']),
    );
  });

  test('管理目录搬迁不会迁移登记关系', () async {
    final root = await Directory.systemTemp.createTemp('gcm-directory-test-');
    addTearDown(() => root.delete(recursive: true));
    final original = await Directory('${root.path}/original').create();
    final registry = DirectoryRegistry(File('${root.path}/registry.json'));
    await registry.register(original.path, 'container:one');
    final moved = await original.rename('${root.path}/moved');
    expect(await registry.query(moved.path), isEmpty);
  });
}
