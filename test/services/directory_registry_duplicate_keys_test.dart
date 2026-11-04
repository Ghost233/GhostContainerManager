import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';

void main() {
  late Directory root;
  late Directory work;
  late String path;
  late File storage;
  late DirectoryRegistry registry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('registry-duplicates-');
    work = await Directory('${root.path}/work').create();
    path = await work.resolveSymbolicLinks();
    storage = File('${root.path}/registry.json');
    registry = DirectoryRegistry(storage);
  });
  tearDown(() async => root.delete(recursive: true));

  final duplicate = isA<FormatException>().having(
    (e) => e.message,
    'message',
    'Duplicate registry object key',
  );

  test('rejects duplicates in valid-shape legacy and v1 files without repair', () async {
    final quotedPath = jsonEncode(path);
    final intent =
        '{"operationId":"op","directory":$quotedPath,"businessName":"b","runtimeName":"r","phase":"prepared"}';
    final cases = [
      '{$quotedPath:["first"],$quotedPath:["second"]}',
      '{"version":1,"version":1,"entries":{},"intents":{}}',
      '{"version":1,"entries":{$quotedPath:[], $quotedPath:["x"]},"intents":{}}',
      '{"version":1,"entries":{},"intents":{"op":$intent,"op":$intent}}',
      '{"version":1,"entries":{},"intents":{"op":{"operationId":"op","directory":$quotedPath,"businessName":"b","runtimeName":"r","phase":"prepared","phase":"prepared"}}}',
      r'{"version":1,"\u0076ersion":1,"entries":{},"intents":{}}',
      r'{"/😀":[],"/\ud83d\ude00":[]}',
      r'{"/a\"b":[],"/a\u0022b":[]}',
      r'{"/a\\b":[],"/a\u005cb":[]}',
      '{"version":1,"entries":{},"intents":{"op":{"operationId":"op","directory":$quotedPath,"businessName":"b","runtimeName":"r","phase":"prepared", "\\u0070hase":"prepared"}}}',
    ];
    for (final contents in cases) {
      await storage.writeAsString(contents);
      await expectLater(
        registry.query(work.path),
        throwsA(duplicate),
        reason: contents,
      );
      await expectLater(
        registry.pendingIntents(),
        throwsA(duplicate),
        reason: contents,
      );
      await expectLater(
        registry.register(work.path, 'new'),
        throwsA(duplicate),
        reason: contents,
      );
      await expectLater(
        registry.createIntent(
          operationId: 'new',
          directory: work.path,
          businessName: 'b',
          runtimeName: 'r',
        ),
        throwsA(duplicate),
        reason: contents,
      );
      expect(await storage.readAsString(), contents);
    }
  });

  test(
    'valid values, escaped strings and independent scopes remain valid',
    () async {
      final q = jsonEncode(path);
      final value = r'quote:" slash:\ braces:{} brackets:[] colon: key';
      final contents = '{$q:[${jsonEncode(value)},"same","same"]}';
      await storage.writeAsString(contents);
      expect(await registry.query(work.path), [value, 'same', 'same']);
      await registry.register(work.path, 'another');
      expect(await DirectoryRegistry(storage).query(work.path), [
        value,
        'same',
        'same',
        'another',
      ]);
      await registry.createIntent(
        operationId: 'one',
        directory: work.path,
        businessName: value,
        runtimeName: value,
      );
      await registry.createIntent(
        operationId: 'two',
        directory: work.path,
        businessName: value,
        runtimeName: value,
      );
      expect(
        (await DirectoryRegistry(
          storage,
        ).pendingIntents()).map((i) => i.operationId),
        ['one', 'two'],
      );
      expect((await registry.readIntent('one'))!.businessName, value);
    },
  );

  test(
    'malformed grammar fails before duplicate scanning without modifying file',
    () async {
      for (final contents in [
        '{"version":1,"version":1,',
        '{"a":"unterminated}',
        '{"a":1,}',
        '[}',
        '',
      ]) {
        await storage.writeAsString(contents);
        await expectLater(
          registry.query(work.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              isNot('Duplicate registry object key'),
            ),
          ),
        );
        expect(await storage.readAsString(), contents);
      }
    },
  );

  test('scans 3000 nested arrays and objects without recursion', () async {
    final deep = '${'[{"a":' * 1500}0${'}]' * 1500}';
    final contents = '{"version":1,"entries":{},"intents":{},"extra":$deep}';
    await storage.writeAsString(contents);
    await expectLater(
      registry.query(work.path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Invalid registry version',
        ),
      ),
    );
    expect(await storage.readAsString(), contents);
    final duplicateDeep =
        '{"version":1,"entries":{},"intents":{},"extra":${'[{"a":' * 1500}{"x":0,"x":1}${'}]' * 1500}}';
    await storage.writeAsString(duplicateDeep);
    await expectLater(registry.query(work.path), throwsA(duplicate));
    expect(await storage.readAsString(), duplicateDeep);
  });
}
