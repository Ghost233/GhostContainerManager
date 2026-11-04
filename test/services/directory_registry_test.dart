import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/project_service.dart';

import 'project_service_test.dart' show FakeProjectCli;

void main() {
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
