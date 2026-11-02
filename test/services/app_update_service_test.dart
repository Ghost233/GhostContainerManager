import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/services/app_update_service.dart';

Map<String, Object?> release({String version = '1.1.2', String? digest}) => {
  'draft': false,
  'prerelease': false,
  'tag_name': 'v$version',
  'assets': [
    {
      'name': 'GhostContainerManager-$version.dmg',
      'size': 100,
      'browser_download_url':
          'https://github.com/Ghost233/GhostContainerManager/releases/download/v$version/GhostContainerManager-$version.dmg',
      'digest': ?digest,
    },
  ],
};
void main() {
  test('reports real release identity, URL and checksum', () async {
    final info = await AppUpdateService(
      currentVersion: '1.1.1',
      readJson: (_) async => release(digest: 'sha256:${'a' * 64}'),
    ).check();
    expect(info.currentVersion, '1.1.1');
    expect(info.latestVersion, '1.1.2');
    expect(info.hasUpdate, isTrue);
    expect(
      info.downloadUrl,
      endsWith('/v1.1.2/GhostContainerManager-1.1.2.dmg'),
    );
    expect(info.sha256, 'a' * 64);
  });
  test('compares numeric components rather than strings', () async {
    final info = await AppUpdateService(
      currentVersion: '1.9.9',
      readJson: (_) async => release(version: '1.10.0'),
    ).check();
    expect(info.hasUpdate, isTrue);
  });
  test('equal and older releases never request a downgrade', () async {
    for (final current in ['1.1.2', '2.0.0']) {
      expect(
        (await AppUpdateService(
          currentVersion: current,
          readJson: (_) async => release(),
        ).check()).hasUpdate,
        isFalse,
      );
    }
  });
  test('falls back to the matching manifest checksum', () async {
    final data = release();
    (data['assets'] as List).add({
      'name': 'manifest.json',
      'browser_download_url': 'https://github.com/Ghost233/GhostContainerManager/releases/download/v1.1.2/manifest.json',
    });
    final calls = <Uri>[];
    final info = await AppUpdateService(
      currentVersion: '1.1.1',
      readJson: (uri) async {
        calls.add(uri);
        return uri == AppUpdateService.latestRelease
            ? data
            : {
                'version': '1.1.2',
                'tag': 'v1.1.2',
                'assets': [
                  {
                    'name': 'GhostContainerManager-1.1.2.dmg',
                    'size': 100,
                    'sha256': 'b' * 64,
                  },
                ],
              };
      },
    ).check();
    expect(calls.length, 2);
    expect(info.sha256, 'b' * 64);
  });
  test('rejects inconsistent update manifests', () async {
    final data = release();
    (data['assets'] as List).add({
      'name': 'manifest.json',
      'browser_download_url': 'https://github.com/Ghost233/GhostContainerManager/releases/download/v1.1.2/manifest.json',
    });
    final service = AppUpdateService(
      currentVersion: '1.1.1',
      readJson: (uri) async =>
          uri == AppUpdateService.latestRelease ? data : {'version': '1.1.1'},
    );
    await expectLater(service.check(), throwsFormatException);
  });
  test('missing package and untrusted download targets fail clearly', () async {
    final missing = release()..['assets'] = [];
    final unsafe = release();
    ((unsafe['assets'] as List).single as Map)['browser_download_url'] =
        'https://example.com/other.dmg';
    for (final value in [
      missing,
      unsafe,
      release()..['prerelease'] = true,
      release()..['tag_name'] = 'invalid',
    ]) {
      await expectLater(
        AppUpdateService(
          currentVersion: '1.1.1',
          readJson: (_) async => value,
        ).check(),
        throwsFormatException,
      );
    }
  });
  test(
    'simultaneous SDK queries share a request; failures can be retried',
    () async {
      final pending = Completer<Map<String, Object?>>();
      var calls = 0;
      final service = AppUpdateService(
        currentVersion: '1.1.1',
        readJson: (_) {
          calls++;
          return calls == 1 ? pending.future : Future.value(release());
        },
      );
      final a = service.check(), b = service.check();
      expect(identical(a, b), isTrue);
      final failed = expectLater(a, throwsA(isA<StateError>()));
      pending.completeError(StateError('offline'));
      await failed;
      expect((await service.check()).hasUpdate, isTrue);
      expect(calls, 2);
    },
  );
  test('development builds do not make misleading update requests', () async {
    var requested = false;
    await expectLater(
      AppUpdateService(
        currentVersion: 'dev',
        readJson: (_) async {
          requested = true;
          return release();
        },
      ).check(),
      throwsFormatException,
    );
    expect(requested, isFalse);
  });
}
