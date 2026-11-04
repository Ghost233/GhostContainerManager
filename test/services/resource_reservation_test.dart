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
    String digest = 'digest',
    String endpoint = 'opaque',
  }) => registry.reserveCreate(
    operationId: op,
    endpoint: endpoint,
    directory: work.path,
    businessName: 'name',
    runtimeName: 'runtime',
    requestDigest: digest,
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
    await expectLater(create('one', digest: 'different'), throwsStateError);
    expect((await create('one')).state, 'unknown');
    await create('different-endpoint', endpoint: 'another');
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

  test('start resource uses endpoint and full container ID', () async {
    final id = 'a' * 64;
    await registry.reserveStart(
      operationId: 'one',
      endpoint: 'e',
      containerId: id,
      requestDigest: 'd',
    );
    await expectLater(
      registry.reserveStart(
        operationId: 'two',
        endpoint: 'e',
        containerId: id,
        requestDigest: 'd',
      ),
      throwsStateError,
    );
    await registry.reserveStart(
      operationId: 'two',
      endpoint: 'e2',
      containerId: id,
      requestDigest: 'd',
    );
    expect(
      () => registry.reserveStart(
        operationId: 'short',
        endpoint: 'e',
        containerId: 'a',
        requestDigest: 'd',
      ),
      throwsFormatException,
    );
  });

  test(
    'legacy data survives and unresolved legacy intents block reservations',
    () async {
      final path = await work.resolveSymbolicLinks();
      await storage.writeAsString(
        jsonEncode({
          path: ['opaque'],
        }),
      );
      await create('new');
      expect(await registry.query(work.path), ['opaque']);
      await registry.createIntent(
        operationId: 'legacy',
        directory: work.path,
        businessName: 'old',
        runtimeName: 'old',
      );
      await expectLater(
        create('blocked', endpoint: 'different'),
        throwsStateError,
      );
      await expectLater(
        registry.createIntent(
          operationId: 'new',
          directory: work.path,
          businessName: 'x',
          runtimeName: 'x',
        ),
        throwsStateError,
      );
    },
  );

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
              endpoint: 'e',
              directory: directory,
              businessName: 'n',
              runtimeName: 'r',
              requestDigest: 'd',
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
}
