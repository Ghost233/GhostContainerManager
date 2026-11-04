import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/container_runtime_identity.dart';
import 'package:ghost_container_manager/services/directory_container_recovery.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';

void main() {
  late Directory temp;
  late DirectoryRegistry registry;
  final id = 'a' * 64;
  final calls = <List<String>>[];
  String? operation;
  String? name;
  var queryMode = 'one';
  var failStart = false;
  var loseResponse = false;
  var failRefresh = false;

  BridgeCommandResult ok(String text) =>
      BridgeCommandResult(exitCode: 0, stdout: text, stderr: '');
  late DirectoryContainerRecovery service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gcm-recovery-');
    registry = DirectoryRegistry(File('${temp.path}/registry.json'));
    calls.clear();
    queryMode = 'one';
    failStart = false;
    loseResponse = false;
    failRefresh = false;
    operation = null;
    name = null;
    final bridge = DockerContainerBridge(
      runner: (args, _) async {
        calls.add(args);
        if (args[1] == 'create') {
          expect(
            await registry.readIntent(
              args
                  .firstWhere(
                    (v) => v.startsWith(
                      '${ContainerRuntimeIdentityService.operationLabel}=',
                    ),
                  )
                  .split('=')
                  .last,
            ),
            isNotNull,
          );
          operation = args
              .firstWhere(
                (v) => v.startsWith(
                  '${ContainerRuntimeIdentityService.operationLabel}=',
                ),
              )
              .split('=')
              .last;
          name = args[args.indexOf('--name') + 1];
          if (loseResponse) throw const BridgeCallException('lost');
          return ok(id);
        }
        if (args[1] == 'ls') {
          if (queryMode == 'unavailable') {
            throw const BridgeCallException('offline');
          }
          if (queryMode == 'zero') return ok('');
          return ok(queryMode == 'multiple' ? '$id\n${'b' * 64}' : id);
        }
        if (args[1] == 'inspect') {
          final actualId = args.last;
          return ok(
            jsonEncode([
              {
                'Id': actualId,
                'Name': '/$name',
                'Config': {
                  'Labels': {
                    ContainerRuntimeIdentityService.productLabel:
                        queryMode == 'badMarker' ? 'false' : 'true',
                    ContainerRuntimeIdentityService.operationLabel: operation,
                  },
                },
              },
            ]),
          );
        }
        if (args[1] == 'start') {
          expect(args.last, id);
          if (failStart) throw const BridgeCallException('start failed');
          return ok('');
        }
        throw StateError('Unexpected $args');
      },
    );
    service = DirectoryContainerRecovery(
      registry: registry,
      bridge: bridge,
      refresh: () async {
        if (failRefresh) throw StateError('refresh');
      },
    );
  });
  tearDown(() async => temp.delete(recursive: true));

  test('creates and registers full ID; recovery is idempotent', () async {
    final result = await service.create(
      directory: temp.path,
      businessName: 'web',
      image: 'image',
      start: true,
    );
    expect(result.status, DirectoryCreationStatus.registered);
    expect(result.containerId, id);
    expect(await registry.query(temp.path), ['container:$id']);
    final recovered = await Future.wait([
      service.recover(result.operationId),
      service.recover(result.operationId),
    ]);
    expect(
      recovered.every((r) => r.status == DirectoryCreationStatus.registered),
      isTrue,
    );
    expect(calls.where((c) => c[1] == 'create').length, 1);
  });

  test('lost response recovers and never recreates', () async {
    loseResponse = true;
    final result = await service.create(
      directory: temp.path,
      businessName: 'web',
      image: 'image',
    );
    expect(result.status, DirectoryCreationStatus.unknown);
    expect(
      (await service.recover(result.operationId)).status,
      DirectoryCreationStatus.registered,
    );
    expect(calls.where((c) => c[1] == 'create').length, 1);
  });

  test(
    'zero, multiple, bad markers and unavailable remain unresolved',
    () async {
      loseResponse = true;
      final result = await service.create(
        directory: temp.path,
        businessName: 'web',
        image: 'image',
      );
      for (final mode in ['zero', 'multiple', 'badMarker', 'unavailable']) {
        queryMode = mode;
        final recovered = await service.recover(result.operationId);
        expect(
          recovered.status,
          mode == 'multiple' || mode == 'badMarker'
              ? DirectoryCreationStatus.conflict
              : DirectoryCreationStatus.unknown,
        );
        expect(await registry.query(temp.path), isEmpty);
      }
    },
  );

  test('start and refresh failures preserve ownership and ID', () async {
    failStart = true;
    final result = await service.create(
      directory: temp.path,
      businessName: 'web',
      image: 'image',
      start: true,
    );
    expect(result.stage, DirectoryCreationStage.start);
    expect(result.containerId, id);
    expect(await registry.query(temp.path), ['container:$id']);
    failStart = false;
    failRefresh = true;
    final retried = await service.retryStart(result.operationId);
    expect(retried.stage, DirectoryCreationStage.refresh);
    expect(retried.containerId, id);
  });

  test('reserved labels and broken registry fail before create', () async {
    await expectLater(
      service.create(
        directory: temp.path,
        businessName: 'web',
        image: 'image',
        labels: {ContainerRuntimeIdentityService.productLabel: 'false'},
      ),
      throwsArgumentError,
    );
    await registry.storage.writeAsString('broken');
    await expectLater(
      service.create(directory: temp.path, businessName: 'web', image: 'image'),
      throwsFormatException,
    );
    expect(calls, isEmpty);
  });
}
