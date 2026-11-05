import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';

void main() {
  late Directory root;
  late Directory work;
  late File storage;
  late DirectoryRegistry registry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reservation-test-');
    work = await Directory('${root.path}/work').create();
    storage = File('${root.path}/registry.json');
    registry = DirectoryRegistry(storage);
  });
  tearDown(() async {
    await Process.run('chmod', ['700', root.path]);
    await root.delete(recursive: true);
  });

  Future<ResourceReservation> create(
    String op, {
    String? digest,
    String? endpoint,
  }) => registry.reserveCreate(
    operationId: op,
    endpoint: endpoint ?? 'b' * 64,
    directory: work.path,
    businessName: 'name',
    runtimeName: 'runtime',
    requestDigest: digest ?? 'a' * 64,
  );

  test(
    'active reservation blocks new legacy intent across namespaces',
    () async {
      await create('one');
      await expectLater(
        registry.createIntent(
          operationId: 'legacy',
          directory: work.path,
          businessName: 'different',
          runtimeName: 'different',
        ),
        throwsStateError,
      );
      expect(await registry.pendingIntents(), isEmpty);
    },
  );

  test('unknown persists and can never be cancelled or bypassed', () async {
    await create('one');
    await registry.markReservationUnknown('one');
    final restarted = DirectoryRegistry(storage);
    expect((await restarted.readReservation('one'))!.state, 'unknown');
    await expectLater(
      restarted.cancelPreparedReservation('one'),
      throwsStateError,
    );
    await expectLater(
      restarted.markReservationUnknown('one'),
      throwsStateError,
    );
    await expectLater(create('two'), throwsStateError);
    await expectLater(
      restarted.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'different',
        runtimeName: 'different',
      ),
      throwsStateError,
    );
    await expectLater(
      restarted.reserveStart(
        operationId: 'start',
        endpoint: 'c' * 64,
        containerId: 'f' * 64,
        requestDigest: 'a' * 64,
      ),
      throwsStateError,
    );
    await expectLater(create('one', digest: 'c' * 64), throwsStateError);
    expect((await create('one')).state, 'unknown');
    await expectLater(
      create('different-endpoint', endpoint: 'c' * 64),
      throwsStateError,
    );
  });

  test(
    'only prepared cancellation frees the resource, never the operation ID',
    () async {
      await create('one');
      await registry.cancelPreparedReservation('one');
      await expectLater(
        registry.markReservationUnknown('one'),
        throwsStateError,
      );
      await expectLater(create('one'), throwsStateError);
      await create('two');
      expect(
        (await DirectoryRegistry(storage).readReservation('one'))!.state,
        'cancelled',
      );
    },
  );

  test(
    'start requires full ID and conservatively blocks other endpoints',
    () async {
      final id = 'a' * 64;
      await registry.reserveStart(
        operationId: 'one',
        endpoint: 'b' * 64,
        containerId: id,
        requestDigest: 'a' * 64,
      );
      await expectLater(
        registry.reserveStart(
          operationId: 'two',
          endpoint: 'b' * 64,
          containerId: id,
          requestDigest: 'a' * 64,
        ),
        throwsStateError,
      );
      await expectLater(
        registry.reserveStart(
          operationId: 'two',
          endpoint: 'c' * 64,
          containerId: id,
          requestDigest: 'a' * 64,
        ),
        throwsStateError,
      );
      expect(
        () => registry.reserveStart(
          operationId: 'short',
          endpoint: 'b' * 64,
          containerId: 'a',
          requestDigest: 'a' * 64,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy data survives and unresolved legacy intents block reservations',
    () async {
      final path = await work.resolveSymbolicLinks();
      await storage.writeAsString(
        jsonEncode({
          path: ['opaque'],
        }),
      );
      expect(await registry.query(work.path), ['opaque']);
      await registry.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'old',
        runtimeName: 'old',
      );
      await expectLater(
        create('blocked', endpoint: 'c' * 64),
        throwsStateError,
      );
      await expectLater(
        registry.createIntent(
          operationId: 'legacy',
          directory: work.path,
          businessName: 'x',
          runtimeName: 'x',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'legacy retries work without reservations and block all reservations',
    () async {
      Future<CreationIntent> legacy() => registry.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'old',
        runtimeName: 'old',
      );
      final first = await legacy();
      expect((await legacy()).operationId, first.operationId);
      final restarted = DirectoryRegistry(storage);
      await expectLater(
        restarted.reserveStart(
          operationId: 'new',
          endpoint: 'c' * 64,
          containerId: 'd' * 64,
          requestDigest: 'a' * 64,
        ),
        throwsStateError,
      );
      expect((await restarted.pendingIntents()).single.operationId, 'legacy');
    },
  );

  test(
    'completed legacy permits reservation and its own idempotent retry',
    () async {
      Future<CreationIntent> legacy() => registry.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'old',
        runtimeName: 'old',
      );
      await legacy();
      for (final phase in [
        CreationPhase.created,
        CreationPhase.registered,
        CreationPhase.completed,
      ]) {
        await registry.advanceIntent('legacy', phase, containerId: 'f' * 64);
      }
      await create('new');
      expect((await legacy()).phase, CreationPhase.completed);
      await expectLater(
        registry.createIntent(
          operationId: 'other',
          directory: work.path,
          businessName: 'old',
          runtimeName: 'old',
        ),
        throwsStateError,
      );
      expect((await create('new')).state, 'prepared');
    },
  );

  test(
    'cancelled tombstone permits legacy and preserves operation IDs',
    () async {
      await create('reserved');
      await registry.cancelPreparedReservation('reserved');
      await registry.cancelPreparedReservation('reserved');
      await registry.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'old',
        runtimeName: 'old',
      );
      await expectLater(
        registry.createIntent(
          operationId: 'reserved',
          directory: work.path,
          businessName: 'old',
          runtimeName: 'old',
        ),
        throwsStateError,
      );
      expect(
        (await DirectoryRegistry(storage).readReservation('reserved'))!.state,
        'cancelled',
      );
    },
  );

  test('mixed active legacy state fails closed without repair', () async {
    await create('reservation');
    final data =
        jsonDecode(await storage.readAsString()) as Map<String, dynamic>;
    (data['intents'] as Map<String, dynamic>)['legacy'] = {
      'operationId': 'legacy',
      'directory': await work.resolveSymbolicLinks(),
      'businessName': 'old',
      'runtimeName': 'old',
      'phase': 'prepared',
      'shouldStart': false,
    };
    final corrupt = jsonEncode(data);
    await storage.writeAsString(corrupt);
    await expectLater(registry.pendingIntents(), throwsFormatException);
    await expectLater(registry.activeReservations(), throwsFormatException);
    await expectLater(
      registry.cancelPreparedReservation('reservation'),
      throwsFormatException,
    );
    await expectLater(
      registry.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'old',
        runtimeName: 'old',
      ),
      throwsFormatException,
    );
    expect(await storage.readAsString(), corrupt);
  });

  test('v2 duplicate keys including escaped keys fail closed', () async {
    await create('one');
    final original = await storage.readAsString();
    for (final corrupt in [
      original.replaceFirst('"version":2', '"version":2,"version":2'),
      original.replaceFirst(
        '"state":"prepared"',
        r'"state":"prepared","sta\u0074e":"unknown"',
      ),
      original.replaceFirst('"reservations":{', '"reservations":{"one":{},'),
    ]) {
      expect(corrupt, isNot(original));
      await storage.writeAsString(corrupt);
      await expectLater(
        registry.activeReservations(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Duplicate registry object key',
          ),
        ),
      );
      await expectLater(registry.readReservation('one'), throwsFormatException);
      await expectLater(registry.pendingIntents(), throwsFormatException);
      await expectLater(registry.readIntent('old'), throwsFormatException);
      await expectLater(registry.query(work.path), throwsFormatException);
      await expectLater(
        registry.register(work.path, 'x'),
        throwsFormatException,
      );
      await expectLater(
        registry.createIntent(
          operationId: 'old',
          directory: work.path,
          businessName: 'b',
          runtimeName: 'r',
        ),
        throwsFormatException,
      );
      await expectLater(create('another'), throwsFormatException);
      await expectLater(
        registry.reserveStart(
          operationId: 'start',
          endpoint: 'b' * 64,
          containerId: 'f' * 64,
          requestDigest: 'a' * 64,
        ),
        throwsFormatException,
      );
      await expectLater(
        registry.markReservationUnknown('one'),
        throwsFormatException,
      );
      await expectLater(
        registry.cancelPreparedReservation('one'),
        throwsFormatException,
      );
      await expectLater(
        registry.advanceIntent(
          'old',
          CreationPhase.created,
          containerId: 'f' * 64,
        ),
        throwsFormatException,
      );
      await expectLater(
        registry.recordIntentFailure('old', CreationFailureStage.create),
        throwsFormatException,
      );
      expect(await storage.readAsString(), corrupt);
    }
  });

  test('corrupt reservation and conflicting stored keys fail closed', () async {
    await create('one');
    final data =
        jsonDecode(await storage.readAsString()) as Map<String, dynamic>;
    final reservations = data['reservations'] as Map<String, dynamic>;
    reservations['two'] = {
      ...reservations['one'] as Map<String, dynamic>,
      'operationId': 'two',
    };
    await storage.writeAsString(jsonEncode(data));
    await expectLater(create('three'), throwsFormatException);
    await expectLater(registry.query(work.path), throwsFormatException);
    reservations['two'] = {'operationId': 'two'};
    await storage.writeAsString(jsonEncode(data));
    await expectLater(registry.readReservation('one'), throwsFormatException);
  });

  test('restart discovers immutable sorted active snapshot', () async {
    expect(await registry.activeReservations(), isEmpty);
    await create('cancel', endpoint: 'd' * 64);
    await registry.cancelPreparedReservation('cancel');
    await create('z');
    await registry.markReservationUnknown('z');
    final restarted = DirectoryRegistry(storage);
    final snapshot = await restarted.activeReservations();
    expect(snapshot.map((r) => r.operationId), ['z']);
    expect(snapshot.map((r) => r.state), ['unknown']);
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(snapshot.map((r) => r.operationId), ['z']);
    expect((await restarted.activeReservations()).map((r) => r.operationId), [
      'z',
    ]);
  });

  test('digest fields reject credentials, URLs and malformed values', () async {
    for (final invalid in [
      '',
      'https://user:password@example.com',
      'user:password',
      'a' * 63,
      'a' * 65,
      'A' * 64,
      'g' * 64,
      '${'a' * 64}\n',
    ]) {
      await expectLater(
        create('invalid', endpoint: invalid),
        throwsFormatException,
      );
      await expectLater(
        create('invalid', digest: invalid),
        throwsFormatException,
      );
      expect(
        () => registry.reserveStart(
          operationId: 'invalid',
          endpoint: invalid,
          containerId: 'f' * 64,
          requestDigest: 'a' * 64,
        ),
        throwsFormatException,
      );
      expect(
        () => registry.reserveStart(
          operationId: 'invalid',
          endpoint: 'b' * 64,
          containerId: 'f' * 64,
          requestDigest: invalid,
        ),
        throwsFormatException,
      );
      expect(await storage.exists(), isFalse);
    }
  });

  test(
    'stored malformed digest fields fail closed without rewriting',
    () async {
      await create('one');
      final original = await storage.readAsString();
      for (final field in ['endpoint', 'requestDigest']) {
        for (final invalid in [
          'https://user:password@example.com',
          'A' * 64,
          'a' * 63,
        ]) {
          final data = jsonDecode(original) as Map<String, dynamic>;
          ((data['reservations'] as Map<String, dynamic>)['one']
                  as Map<String, dynamic>)[field] =
              invalid;
          final corrupt = jsonEncode(data);
          await storage.writeAsString(corrupt);
          await expectLater(
            registry.activeReservations(),
            throwsFormatException,
          );
          await expectLater(
            registry.readReservation('one'),
            throwsFormatException,
          );
          await expectLater(create('two'), throwsFormatException);
          expect(await storage.readAsString(), corrupt);
        }
      }
    },
  );

  test(
    'rejects non-digest inputs and persists supplied digest-shaped values',
    () async {
      const rawEndpoint = 'https://user:password@example.com';
      const rawRequest = 'credential-token';
      await expectLater(
        create('bad-endpoint', endpoint: rawEndpoint),
        throwsFormatException,
      );
      await expectLater(
        create('bad-request', digest: rawRequest),
        throwsFormatException,
      );
      expect(await storage.exists(), isFalse);
      await create('one');
      final contents = await storage.readAsString();
      expect(contents, contains('a' * 64));
      expect(contents, contains('b' * 64));
      expect(contents, isNot(contains(rawEndpoint)));
      expect(contents, isNot(contains(rawRequest)));
      expect(contents, isNot(contains('password')));
    },
  );

  test('lock and write failures never grant dispatch permission', () async {
    // A directory at the lock path prevents even the initial reservation.
    await Directory('${storage.path}.lock').create();
    var dispatched = false;
    await expectLater(() async {
      await create('lock-failure');
      dispatched = true;
    }(), throwsA(isA<FileSystemException>()));
    expect(dispatched, isFalse);
    expect(await storage.exists(), isFalse);
    await Directory('${storage.path}.lock').delete();

    await registry.register(work.path, 'opaque');
    final initial = await storage.readAsString();
    expect((await Process.run('chmod', ['500', root.path])).exitCode, 0);
    await expectLater(
      create('write-failure'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await storage.readAsString(), initial);
    expect(await registry.activeReservations(), isEmpty);
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    await create('prepared');
    final before = await storage.readAsString();
    expect((await Process.run('chmod', ['500', root.path])).exitCode, 0);
    await expectLater(() async {
      await registry.markReservationUnknown('prepared');
      dispatched = true;
    }(), throwsA(isA<FileSystemException>()));
    expect(dispatched, isFalse);
    expect(await storage.readAsString(), before);
    expect(
      (await DirectoryRegistry(storage).activeReservations()).single.state,
      'prepared',
    );
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    await registry.cancelPreparedReservation('prepared');
  });

  test('mark and cancel race has exactly one winner', () async {
    await create('one');
    final results = await Future.wait([
      () async {
        try {
          await registry.markReservationUnknown('one');
          return true;
        } on StateError {
          return false;
        }
      }(),
      () async {
        try {
          await DirectoryRegistry(storage).cancelPreparedReservation('one');
          return true;
        } on StateError {
          return false;
        }
      }(),
    ]);
    expect(results.where((r) => r), hasLength(1));
  });

  test('cross-isolate contenders cannot both reserve', () async {
    final path = storage.path;
    final directory = work.path;
    final results = await Future.wait(
      List.generate(
        6,
        (i) => Isolate.run(() async {
          try {
            await DirectoryRegistry(File(path)).reserveCreate(
              operationId: 'op$i',
              endpoint: 'b' * 64,
              directory: directory,
              businessName: 'n',
              runtimeName: 'r',
              requestDigest: 'a' * 64,
            );
            return true;
          } on StateError {
            return false;
          }
        }),
      ),
    );
    expect(results.where((r) => r), hasLength(1));
  });

  test(
    'cross-isolate legacy and reservation have exactly one winner',
    () async {
      final path = storage.path;
      final directory = work.path;
      final results = await Future.wait(
        List.generate(
          2,
          (i) => Isolate.run(() async {
            final other = DirectoryRegistry(File(path));
            try {
              if (i == 0) {
                await other.createIntent(
                  operationId: 'legacy',
                  directory: directory,
                  businessName: 'old',
                  runtimeName: 'old',
                );
              } else {
                await other.reserveStart(
                  operationId: 'new',
                  endpoint: 'c' * 64,
                  containerId: 'd' * 64,
                  requestDigest: 'a' * 64,
                );
              }
              return true;
            } on StateError {
              return false;
            }
          }),
        ),
      );
      expect(results.where((r) => r), hasLength(1));
      final restarted = DirectoryRegistry(storage);
      expect(
        (await restarted.pendingIntents()).length +
            (await restarted.activeReservations()).length,
        1,
      );
    },
  );

  test('cross-process contenders cannot both reserve', () async {
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
    final processes = await Future.wait(
      List.generate(
        4,
        (i) => Process.run('$sdk/bin/dart', [
          'run',
          'test/support/reservation_process.dart',
          storage.path,
          'op$i',
          work.path,
        ]),
      ),
    );
    expect(processes.map((p) => p.exitCode), everyElement(0));
    expect(processes.where((p) => p.stdout == 'won'), hasLength(1));
    expect(processes.where((p) => p.stdout == 'collision'), hasLength(3));
  });

  test(
    'cross-process legacy and reservation have exactly one winner',
    () async {
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
      final results = await Future.wait([
        Process.run('$sdk/bin/dart', [
          'run',
          'test/support/reservation_process.dart',
          storage.path,
          'legacy',
          work.path,
          'legacy',
        ]),
        Process.run('$sdk/bin/dart', [
          'run',
          'test/support/reservation_process.dart',
          storage.path,
          'new',
          work.path,
        ]),
      ]);
      expect(results.map((p) => p.exitCode), everyElement(0));
      expect(results.where((p) => p.stdout == 'won'), hasLength(1));
      expect(results.where((p) => p.stdout == 'collision'), hasLength(1));
      final restarted = DirectoryRegistry(storage);
      expect(
        (await restarted.pendingIntents()).length +
            (await restarted.activeReservations()).length,
        1,
      );
    },
  );
}
