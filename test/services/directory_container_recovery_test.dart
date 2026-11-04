import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/container_runtime_identity.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/directory_container_recovery.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';

class FaultRegistry extends DirectoryRegistry {
  FaultRegistry(super.storage);
  bool failCreated = false;

  @override
  Future<CreationIntent> advanceIntent(
    String operationId,
    CreationPhase phase, {
    String? containerId,
  }) {
    if (failCreated && phase == CreationPhase.created) {
      throw FileSystemException('injected write failure');
    }
    return super.advanceIntent(operationId, phase, containerId: containerId);
  }
}

void main() {
  late Directory temp;
  late FaultRegistry registry;
  final id = 'a' * 64;
  final calls = <List<String>>[];
  String? operation;
  String? name;
  var queryMode = 'one';
  var failStart = false;
  var loseResponse = false;
  var failRefresh = false;
  var running = false;
  late ContainerService management;
  late DockerContainerBridge bridge;
  Completer<void>? blockRefresh;

  BridgeCommandResult ok(String text) =>
      BridgeCommandResult(exitCode: 0, stdout: text, stderr: '');
  late DirectoryContainerRecovery service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gcm-recovery-');
    registry = FaultRegistry(File('${temp.path}/registry.json'));
    calls.clear();
    queryMode = 'one';
    failStart = false;
    loseResponse = false;
    failRefresh = false;
    running = false;
    blockRefresh = null;
    operation = null;
    name = null;
    bridge = DockerContainerBridge(
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
          if (!args.contains('--filter')) {
            await blockRefresh?.future;
            return ok('');
          }
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
                'State': {
                  'Status': running ? 'running' : 'created',
                  'Running': running,
                },
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
          running = true;
          return ok('');
        }
        throw StateError('Unexpected $args');
      },
    );
    management = ContainerService(bridge: bridge, directoryRegistry: registry);
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

  test('unique match after unknown create remains pending without termination proof', () async {
    loseResponse = true;
    final result = await service.create(
      directory: temp.path,
      businessName: 'web',
      image: 'image',
      start: true,
    );
    expect(result.status, DirectoryCreationStatus.unknown);
    final recovered = await service.recover(result.operationId);
    expect(recovered.status, DirectoryCreationStatus.unknown);
    expect(recovered.containerId, id);
    expect(
      (await registry.readIntent(result.operationId))!.phase,
      CreationPhase.prepared,
    );
    expect(await registry.query(temp.path), isEmpty);
    expect(calls.where((c) => c[1] == 'create').length, 1);
    expect(calls.where((c) => c[1] == 'start'), isEmpty);
  });

  test('prepared intent with unique match remains pending', () async {
    operation = 'still-in-flight';
    name = 'gcm-still-in-flight';
    await registry.createIntent(
      operationId: operation!,
      directory: temp.path,
      businessName: 'web',
      runtimeName: name!,
      shouldStart: true,
    );
    final result = await management.directoryRecovery!.recover(operation!);
    expect(result.status, DirectoryCreationStatus.unknown);
    expect(await registry.query(temp.path), isEmpty);
    expect(
      calls.where((call) => call[1] == 'start' || call[1] == 'create'),
      isEmpty,
    );
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
    expect(
      (await registry.readIntent(result.operationId))!.failureStage,
      CreationFailureStage.start,
    );
    failStart = false;
    service = DirectoryContainerRecovery(
      registry: DirectoryRegistry(registry.storage),
      bridge: bridge,
      refresh: () async {
        if (failRefresh) throw StateError('refresh');
      },
    );
    final retried = await service.retryStart(result.operationId);
    expect(retried.status, DirectoryCreationStatus.unknown);
    expect(retried.stage, DirectoryCreationStage.start);
    expect(calls.where((c) => c[1] == 'start').length, 1);
    running = true;
    failRefresh = true;
    final reconciled = await service.recover(result.operationId);
    expect(reconciled.status, DirectoryCreationStatus.unknown);
    expect(reconciled.stage, DirectoryCreationStage.start);
    expect(reconciled.containerId, id);
    expect(calls.where((c) => c[1] == 'start').length, 1);
    expect(
      (await registry.readIntent(result.operationId))!.failureStage,
      CreationFailureStage.start,
    );
  });

  test(
    'known ID is reported but cannot prove termination after write failure',
    () async {
      registry.failCreated = true;
      final result = await management.directoryRecovery!.create(
        directory: temp.path,
        businessName: 'web',
        image: 'image',
      );
      expect(result.containerId, id);
      expect(result.stage, DirectoryCreationStage.storage);
      expect(
        (await registry.readIntent(result.operationId))!.phase,
        CreationPhase.prepared,
      );
      registry.failCreated = false;
      final mismatch = await management.directoryRecovery!.recover(
        result.operationId,
        expectedContainerId: 'b' * 64,
      );
      expect(mismatch.status, DirectoryCreationStatus.conflict);
      final recovered = await management.directoryRecovery!.recover(
        result.operationId,
        expectedContainerId: id,
      );
      expect(recovered.status, DirectoryCreationStatus.unknown);
      expect(recovered.containerId, id);
      expect(await registry.query(temp.path), isEmpty);
      expect(calls.where((c) => c[1] == 'create').length, 1);
    },
  );

  test('in-flight global refresh does not complete recovery', () async {
    blockRefresh = Completer<void>();
    final inFlight = management.refresh();
    final result = await management.directoryRecovery!.create(
      directory: temp.path,
      businessName: 'web',
      image: 'image',
    );
    expect(result.stage, DirectoryCreationStage.refresh);
    expect(
      (await registry.readIntent(result.operationId))!.failureStage,
      CreationFailureStage.refresh,
    );
    blockRefresh!.complete();
    await inFlight;
    expect(
      (await management.directoryRecovery!.recover(result.operationId)).status,
      DirectoryCreationStatus.registered,
    );
  });

  test('shared container management entry creates and completes', () async {
    final result = await management.directoryRecovery!.create(
      directory: temp.path,
      businessName: 'web',
      image: 'image',
    );
    expect(result.status, DirectoryCreationStatus.registered);
    expect(
      (await registry.readIntent(result.operationId))!.phase,
      CreationPhase.completed,
    );
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
