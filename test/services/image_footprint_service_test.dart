import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/services/image_footprint_service.dart';

void main() {
  group('ImageFootprintService', () {
    late Directory temp;
    late String appRoot;
    late String cacheFilePath;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('gcm-image-footprint-');
      appRoot = '${temp.path}/container';
      cacheFilePath = '${temp.path}/support/image-footprint-cache.json';
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('streams every gzip layer of a direct manifest', () async {
      final manifest = digest(1);
      final firstLayer = digest(2);
      final secondLayer = digest(3);
      writeGzipBlob(appRoot, firstLayer, 16384);
      writeGzipBlob(appRoot, secondLayer, 9000);
      writeManifest(appRoot, manifest, [
        layer(firstLayer, 500),
        layer(secondLayer, 600),
      ]);
      final service = ImageFootprintService(cacheFilePath: cacheFilePath);

      final size = await service.expandedSizeBytes(
        digest: manifest,
        appRoot: appRoot,
      );

      expect(size, 25384);
    });

    test('selects the arm64 Linux manifest from an OCI index', () async {
      final index = digest(10);
      final armManifest = digest(11);
      final amdManifest = digest(12);
      final armLayer = digest(13);
      final amdLayer = digest(14);
      writeGzipBlob(appRoot, armLayer, 5000);
      writeGzipBlob(appRoot, amdLayer, 9000);
      writeManifest(appRoot, armManifest, [layer(armLayer, 300)]);
      writeManifest(appRoot, amdManifest, [layer(amdLayer, 400)]);
      writeJsonBlob(appRoot, index, {
        'schemaVersion': 2,
        'manifests': [
          {
            'digest': amdManifest,
            'platform': {'architecture': 'amd64', 'os': 'linux'},
          },
          {
            'digest': armManifest,
            'platform': {'architecture': 'arm64', 'os': 'linux'},
          },
        ],
      });
      final service = ImageFootprintService(cacheFilePath: cacheFilePath);

      final size = await service.expandedSizeBytes(
        digest: index,
        appRoot: appRoot,
      );

      expect(size, 5000);
    });

    test('disk cache avoids reading or decompressing a blob again', () async {
      final manifest = digest(20);
      final layerDigest = digest(21);
      writeGzipBlob(appRoot, layerDigest, 8192);
      writeManifest(appRoot, manifest, [layer(layerDigest, 200)]);
      final first = ImageFootprintService(cacheFilePath: cacheFilePath);
      expect(
        await first.expandedSizeBytes(digest: manifest, appRoot: appRoot),
        8192,
      );
      final cache = jsonDecode(await File(cacheFilePath).readAsString());
      expect(cache[layerDigest], 8192);

      File(blobPath(appRoot, layerDigest)).deleteSync();
      final second = ImageFootprintService(cacheFilePath: cacheFilePath);
      expect(
        await second.expandedSizeBytes(digest: manifest, appRoot: appRoot),
        8192,
      );
    });

    test('concurrent readers share one in-flight blob decompression', () async {
      final manifest = digest(25);
      final layerDigest = digest(26);
      writeGzipBlob(appRoot, layerDigest, 4096);
      writeManifest(appRoot, manifest, [layer(layerDigest, 200)]);
      final decoderGate = Completer<void>();
      var decoderCalls = 0;
      final service = ImageFootprintService(
        cacheFilePath: cacheFilePath,
        gzipDecoderFactory: () {
          decoderCalls += 1;
          return StreamTransformer<List<int>, List<int>>.fromBind((
            source,
          ) async* {
            await decoderGate.future;
            yield* source.transform(gzip.decoder);
          });
        },
      );

      final first = service.expandedSizeBytes(
        digest: manifest,
        appRoot: appRoot,
      );
      final second = service.expandedSizeBytes(
        digest: manifest,
        appRoot: appRoot,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      decoderGate.complete();

      expect(await Future.wait([first, second]), [4096, 4096]);
      expect(decoderCalls, 1);
    });

    test('layerDiskBytes allocates index, manifest and layer blobs', () async {
      final index = digest(50);
      final manifest = digest(51);
      final layerDigest = digest(52);
      writeGzipBlob(appRoot, layerDigest, 4096);
      writeManifest(appRoot, manifest, [layer(layerDigest, 200)]);
      writeJsonBlob(appRoot, index, {
        'schemaVersion': 2,
        'manifests': [
          {
            'digest': manifest,
            'platform': {'architecture': 'arm64', 'os': 'linux'},
          },
        ],
      });
      final service = ImageFootprintService(cacheFilePath: cacheFilePath);

      final bytes = await service.layerDiskBytes(
        digest: index,
        appRoot: appRoot,
      );

      // Real files on a real filesystem: an allocation is always positive.
      expect(bytes, greaterThan(0));
      expect(
        bytes,
        greaterThanOrEqualTo(
          File(blobPath(appRoot, layerDigest)).lengthSync() +
              File(blobPath(appRoot, manifest)).lengthSync() +
              File(blobPath(appRoot, index)).lengthSync(),
        ),
      );
    });

    test('footprintFor combines expanded, layer and container bytes', () async {
      final manifest = digest(60);
      final layerDigest = digest(61);
      writeGzipBlob(appRoot, layerDigest, 8192);
      writeManifest(appRoot, manifest, [layer(layerDigest, 200)]);
      final requested = <String>[];
      final service = ImageFootprintService(
        cacheFilePath: cacheFilePath,
        directoryBytes: (path) async {
          requested.add(path);
          return path.endsWith('/web') ? 4096 : 1024;
        },
      );

      final footprint = await service.footprintFor(
        digest: manifest,
        containerIds: const <String>['web', 'worker'],
        appRoot: appRoot,
      );

      expect(footprint.expandedBytes, 8192);
      expect(footprint.layerDiskBytes, greaterThan(0));
      expect(footprint.containerDiskBytes, 4096 + 1024);
      expect(footprint.actualDiskBytes, footprint.layerDiskBytes + 5120);
      expect(requested, <String>[
        '$appRoot/containers/web',
        '$appRoot/containers/worker',
      ]);
    });

    test('missing container directories contribute zero', () async {
      final manifest = digest(70);
      final layerDigest = digest(71);
      writeGzipBlob(appRoot, layerDigest, 2048);
      writeManifest(appRoot, manifest, [layer(layerDigest, 200)]);
      final service = ImageFootprintService(
        cacheFilePath: cacheFilePath,
        directoryBytes: (_) async => 0,
      );

      final footprint = await service.footprintFor(
        digest: manifest,
        containerIds: const <String>['gone'],
        appRoot: appRoot,
      );

      expect(footprint.containerDiskBytes, 0);
      expect(footprint.expandedBytes, 2048);
    });

    test(
      'a missing layer blob is unavailable instead of a fake size',
      () async {
        final manifest = digest(30);
        writeManifest(appRoot, manifest, [layer(digest(31), 100)]);
        final service = ImageFootprintService(cacheFilePath: cacheFilePath);

        expect(
          await service.expandedSizeBytes(digest: manifest, appRoot: appRoot),
          isNull,
        );
      },
    );

    test('a non-gzip layer makes the expanded size unavailable', () async {
      final manifest = digest(40);
      final zstdLayer = digest(41);
      File(blobPath(appRoot, zstdLayer))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      writeManifest(appRoot, manifest, [
        layer(
          zstdLayer,
          3,
          mediaType: 'application/vnd.oci.image.layer.v1.tar+zstd',
        ),
      ]);
      final service = ImageFootprintService(cacheFilePath: cacheFilePath);

      expect(
        await service.expandedSizeBytes(digest: manifest, appRoot: appRoot),
        isNull,
      );
    });
  });
}

String digest(int value) =>
    'sha256:${value.toRadixString(16).padLeft(64, '0')}';

String blobPath(String appRoot, String digest) =>
    '$appRoot/content/blobs/sha256/${digest.substring('sha256:'.length)}';

Map<String, Object?> layer(
  String digest,
  int size, {
  String mediaType = 'application/vnd.oci.image.layer.v1.tar+gzip',
}) => {'digest': digest, 'mediaType': mediaType, 'size': size};

void writeManifest(
  String appRoot,
  String digest,
  List<Map<String, Object?>> layers,
) {
  writeJsonBlob(appRoot, digest, {
    'schemaVersion': 2,
    'mediaType': 'application/vnd.oci.image.manifest.v1+json',
    'layers': layers,
  });
}

void writeGzipBlob(String appRoot, String digest, int uncompressedSize) {
  final content = List<int>.generate(uncompressedSize, (i) => i % 251);
  File(blobPath(appRoot, digest))
    ..createSync(recursive: true)
    ..writeAsBytesSync(gzip.encode(content));
}

void writeJsonBlob(String appRoot, String digest, Object? value) {
  File(blobPath(appRoot, digest))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(value));
}
