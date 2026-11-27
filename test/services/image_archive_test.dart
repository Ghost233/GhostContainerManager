import 'dart:io';

import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/image_archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _abcSha =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _zeroSha =
    '0000000000000000000000000000000000000000000000000000000000000000';

void main() {
  late Directory tmp;
  late String file;
  late List<List<String>> calls;
  late ImageArchiveService service;
  late bool failSave;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gcm-archive-test-');
    file = '${tmp.path}/release.tar';
    calls = [];
    failSave = false;
    service = ImageArchiveService(
      DockerContainerBridge(
        runner: (args, timeout) async {
          calls.add([...args]);
          if (args.join(' ') == 'context show') {
            return const BridgeCommandResult(
              exitCode: 0,
              stdout: 'japan\n',
              stderr: '',
            );
          }
          switch (args[1]) {
            case 'save':
              expect(args.take(3), ['image', 'save', '--output']);
              expect(args[4], 'busybox:stable');
              await File(args[3]).writeAsString('abc');
              return BridgeCommandResult(
                exitCode: failSave ? 1 : 0,
                stdout: '',
                stderr: '',
              );
            case 'load':
              expect(args.take(3), ['image', 'load', '--input']);
              expect(args[3], isNot(file));
              expect(await File(args[3]).readAsString(), 'abc');
              return const BridgeCommandResult(
                exitCode: 0,
                stdout: 'Loaded image: busybox:stable\n',
                stderr: '',
              );
          }
          throw StateError('unexpected Docker command');
        },
      ),
    );
  });

  tearDown(() async => tmp.delete(recursive: true));

  test('paired archive keeps bytes and reports context and hash', () async {
    final exported = await service.save('busybox:stable', file);
    expect(exported['context'], 'japan');
    expect(exported['sha256'], _abcSha);
    expect(exported['bytes'], 3);
    expect(await File(file).readAsString(), 'abc');
    final imported = await service.load(
      file,
      expectedSha256: _abcSha,
      confirmTagChanges: true,
    );
    expect(imported['context'], 'japan');
    expect(imported['loadedReferences'], ['busybox:stable']);
    expect(imported['sha256'], _abcSha);
    expect(calls.map((x) => x.take(2).join(' ')), [
      'context show',
      'image save',
      'context show',
      'image load',
    ]);
    expect(await File(calls[1][3]).exists(), isFalse);
    expect(await File(calls[3][3]).exists(), isFalse);
  });

  test(
    'checksum mismatch and missing confirmation never execute Docker load',
    () async {
      await File(file).writeAsString('abc');
      for (final (hash, confirmation) in [(_zeroSha, true), (_abcSha, false)]) {
        await expectLater(
          service.load(
            file,
            expectedSha256: hash,
            confirmTagChanges: confirmation,
          ),
          throwsA(
            isA<GcmException>().having(
              (e) => e.code,
              'code',
              GcmErrorCode.invalidArgument,
            ),
          ),
        );
      }
      expect(calls.where((x) => x.first == 'image'), isEmpty);
    },
  );

  test('export never overwrites and import refuses a symbolic link', () async {
    await File(file).writeAsString('keep');
    await expectLater(
      service.save('busybox:stable', file),
      throwsA(isA<GcmException>()),
    );
    expect(await File(file).readAsString(), 'keep');
    final link = '${tmp.path}/link.tar';
    await Link(link).create(file);
    await expectLater(
      service.load(link, expectedSha256: _abcSha, confirmTagChanges: true),
      throwsA(isA<GcmException>()),
    );
    expect(calls, isEmpty);
  });

  test(
    'failed Docker save neither publishes nor leaves partial file',
    () async {
      failSave = true;
      await expectLater(
        service.save('busybox:stable', file),
        throwsA(isA<GcmException>()),
      );
      expect(await File(file).exists(), isFalse);
      expect(await tmp.list().toList(), isEmpty);
    },
  );
}
