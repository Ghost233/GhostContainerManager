import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ghost_container_manager/services/app_constants.dart';

/// One image's three size readings, all in bytes.
///
/// * [expandedBytes] — the sum of uncompressed layer sizes (Docker's virtual
///   size). Null when a layer uses compression this build cannot decode.
/// * [layerDiskBytes] — the actual blocks occupied by the image's OCI blobs.
/// * [containerDiskBytes] — the actual blocks occupied by the containers that
///   were created from this image (`rootfs.ext4` is sparse; apparent sizes
///   are meaningless here).
class ImageDiskFootprint {
  const ImageDiskFootprint({
    required this.expandedBytes,
    required this.layerDiskBytes,
    required this.containerDiskBytes,
  });

  final int? expandedBytes;
  final int layerDiskBytes;
  final int containerDiskBytes;

  /// What the image + its containers really cost on disk.
  int get actualDiskBytes => layerDiskBytes + containerDiskBytes;
}

/// Resolves logical (uncompressed) image sizes from the runtime's OCI store.
///
/// The container store is read-only. The only persisted output is the
/// content-addressed layer-size cache owned by this application.
class ImageFootprintService {
  ImageFootprintService({
    String? cacheFilePath,
    StreamTransformer<List<int>, List<int>> Function()? gzipDecoderFactory,
    Future<int> Function(String path)? directoryBytes,
  }) : _cacheFilePath = cacheFilePath ?? _defaultCacheFilePath(),
       _gzipDecoderFactory = gzipDecoderFactory ?? (() => gzip.decoder),
       _directoryBytes = directoryBytes ?? directoryDiskBytes;

  final String _cacheFilePath;
  final StreamTransformer<List<int>, List<int>> Function() _gzipDecoderFactory;
  final Future<int> Function(String path) _directoryBytes;
  final Map<String, int> _cache = <String, int>{};
  final Map<String, Future<int?>> _inflight = <String, Future<int?>>{};
  Future<void>? _cacheLoad;
  Future<void> _cacheWrite = Future<void>.value();

  /// Returns the sum of uncompressed layer sizes, or null when unavailable.
  ///
  /// Both an OCI index digest and a direct manifest digest are accepted. An
  /// index is resolved to its arm64/Linux manifest. Unsupported compression,
  /// missing blobs, and malformed runtime data are unavailable, not zero.
  Future<int?> expandedSizeBytes({
    required String digest,
    String? appRoot,
  }) async {
    final root = appRoot ?? _defaultAppRoot();
    await _ensureCacheLoaded();
    final manifest = await _resolveManifest(root, digest);
    final layers = manifest?['layers'];
    if (layers is! List) return null;

    var total = 0;
    for (final rawLayer in layers) {
      if (rawLayer is! Map) return null;
      final layerDigest = rawLayer['digest'];
      final mediaType = rawLayer['mediaType'];
      if (layerDigest is! String ||
          mediaType is! String ||
          !_isGzip(mediaType)) {
        return null;
      }
      final size = await _layerSizeBytes(root, layerDigest);
      if (size == null) return null;
      total += size;
    }
    return total;
  }

  /// Actual disk blocks of one image's OCI blobs (index + manifest + layers).
  ///
  /// Sparse-aware: uses the file's allocated block count, not its length.
  Future<int> layerDiskBytes({required String digest, String? appRoot}) async {
    final root = appRoot ?? _defaultAppRoot();
    final blobs = <String>{digest};
    final manifest = await _resolveManifest(root, digest);
    final layers = manifest?['layers'];
    if (layers is List) {
      for (final rawLayer in layers) {
        if (rawLayer is Map) {
          final layerDigest = rawLayer['digest'];
          if (layerDigest is String) blobs.add(layerDigest);
        }
      }
    }
    final manifestDigest = await _arm64ManifestDigest(root, digest);
    if (manifestDigest != null) blobs.add(manifestDigest);

    var total = 0;
    for (final blobDigest in blobs) {
      final file = _blobFile(root, blobDigest);
      if (file == null) continue;
      total += await fileAllocatedBytes(file);
    }
    return total;
  }

  /// One-stop footprint for an image and the containers created from it.
  ///
  /// [containerIds] are container names/ids; their directories are looked up
  /// under the same app root. Missing directories contribute zero.
  Future<ImageDiskFootprint> footprintFor({
    required String digest,
    required List<String> containerIds,
    String? appRoot,
  }) async {
    final root = appRoot ?? _defaultAppRoot();
    final expanded = await expandedSizeBytes(digest: digest, appRoot: root);
    final layers = await layerDiskBytes(digest: digest, appRoot: root);
    var containers = 0;
    for (final id in containerIds) {
      containers += await _directoryBytes(containerDirectory(id, root));
    }
    return ImageDiskFootprint(
      expandedBytes: expanded,
      layerDiskBytes: layers,
      containerDiskBytes: containers,
    );
  }

  /// Actual disk bytes of one container's runtime directory.
  Future<int> containerDirectoryBytes(String id, {String? appRoot}) =>
      _directoryBytes(containerDirectory(id, appRoot ?? defaultAppRoot()));

  /// Path of a container's runtime directory (disk images live here).
  static String containerDirectory(String id, String appRoot) {
    final prefix = appRoot.endsWith('/')
        ? appRoot.substring(0, appRoot.length - 1)
        : appRoot;
    return '$prefix/containers/$id';
  }

  /// Actual allocated bytes for a directory tree (`du -sk`, sparse-aware).
  static Future<int> directoryDiskBytes(String path) async {
    try {
      final result = await Process.run('du', <String>['-sk', path]);
      if (result.exitCode != 0) return 0;
      final kib = int.tryParse(
        '${result.stdout}'.trim().split(RegExp(r'\s+')).first,
      );
      return kib == null ? 0 : kib * 1024;
    } on Exception {
      return 0;
    }
  }

  /// Actual allocated bytes for one file (`stat -f %b` × 512).
  @visibleForTesting
  static Future<int> fileAllocatedBytes(File file) async {
    if (!await file.exists()) return 0;
    try {
      final result = await Process.run('stat', <String>['-f', '%b', file.path]);
      if (result.exitCode != 0) return 0;
      final blocks = int.tryParse('${result.stdout}'.trim());
      return blocks == null ? 0 : blocks * 512;
    } on Exception {
      return 0;
    }
  }

  Future<String?> _arm64ManifestDigest(String root, String digest) async {
    final document = await _readJsonObject(root, digest);
    if (document == null || document['layers'] is List) return null;
    final manifests = document['manifests'];
    if (manifests is! List) return null;
    for (final candidate in manifests) {
      if (candidate is! Map) continue;
      final platform = candidate['platform'];
      if (platform is! Map ||
          platform['architecture'] != 'arm64' ||
          platform['os'] != 'linux') {
        continue;
      }
      final manifestDigest = candidate['digest'];
      if (manifestDigest is String) return manifestDigest;
    }
    return null;
  }

  Future<Map<String, Object?>?> _resolveManifest(
    String root,
    String digest,
  ) async {
    final document = await _readJsonObject(root, digest);
    if (document == null) return null;
    if (document['layers'] is List) return document;

    final manifests = document['manifests'];
    if (manifests is! List) return null;
    for (final candidate in manifests) {
      if (candidate is! Map) continue;
      final platform = candidate['platform'];
      if (platform is! Map ||
          platform['architecture'] != 'arm64' ||
          platform['os'] != 'linux') {
        continue;
      }
      final manifestDigest = candidate['digest'];
      if (manifestDigest is String) {
        return _readJsonObject(root, manifestDigest);
      }
    }
    return null;
  }

  Future<int?> _layerSizeBytes(String root, String digest) {
    final cached = _cache[digest];
    if (cached != null) return Future<int?>.value(cached);
    final pending = _inflight[digest];
    if (pending != null) return pending;

    final operation = _decodeAndCache(root, digest);
    _inflight[digest] = operation;
    return operation.whenComplete(() {
      if (identical(_inflight[digest], operation)) {
        _inflight.remove(digest);
      }
    });
  }

  Future<int?> _decodeAndCache(String root, String digest) async {
    final size = await _decodeGzipSize(root, digest);
    if (size != null) {
      _cache[digest] = size;
      await _persistCache();
    }
    return size;
  }

  Future<int?> _decodeGzipSize(String root, String digest) async {
    final file = _blobFile(root, digest);
    if (file == null) return null;
    try {
      var size = 0;
      await for (final chunk in file.openRead().transform(
        _gzipDecoderFactory(),
      )) {
        size += chunk.length;
      }
      return size;
    } on Exception {
      return null;
    }
  }

  Future<Map<String, Object?>?> _readJsonObject(
    String root,
    String digest,
  ) async {
    final file = _blobFile(root, digest);
    if (file == null) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) return decoded;
    } on Exception {
      return null;
    }
    return null;
  }

  Future<void> _ensureCacheLoaded() => _cacheLoad ??= _loadCache();

  Future<void> _loadCache() async {
    try {
      final decoded = jsonDecode(await File(_cacheFilePath).readAsString());
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is int && value >= 0) {
          _cache[key] = value;
        }
      }
    } on Exception {
      // A missing or malformed cache must not hide the image list.
    }
  }

  Future<void> _persistCache() {
    final snapshot = jsonEncode(_cache);
    final write = _cacheWrite
        .then((_) async {
          final file = File(_cacheFilePath);
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(snapshot, flush: true);
          await temporary.rename(file.path);
        })
        .catchError((_) {
          // A cache-write failure does not invalidate the measured result.
        });
    _cacheWrite = write;
    return write;
  }

  static bool _isGzip(String mediaType) =>
      mediaType.endsWith('+gzip') || mediaType.endsWith('.gzip');

  static File? _blobFile(String root, String digest) {
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest)) return null;
    final prefix = root.endsWith('/')
        ? root.substring(0, root.length - 1)
        : root;
    return File(
      '$prefix/content/blobs/sha256/${digest.substring('sha256:'.length)}',
    );
  }

  static String _defaultAppRoot() => defaultAppRoot();

  /// Runtime application-support root; overridden by `paths.appRoot` when the
  /// system status payload provides it.
  static String defaultAppRoot() {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/Library/Application Support/com.apple.container';
  }

  static String _defaultCacheFilePath() {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/Library/Application Support/$applicationBundleId/'
        'image-footprint-cache.json';
  }
}
