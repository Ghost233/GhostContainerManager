/// Image domain models (T5, issue #20): list snapshots, inspect summaries,
/// pull progress, and the name:tag addressing contract
/// (docs/spec/mcp-tools.md §3.2; 寻址一律 name:tag，禁裸 digest——
/// 上游 digest 寻址会误回退 docker.io，apple/container#1962)。
library;

import 'errors.dart';

/// Validates a user-supplied image reference and returns the normalized
/// `name:tag` form (tag-less input defaults to `:latest`, matching upstream
/// CLI behaviour).
///
/// Digest addressing (`name@sha256:…` or a bare digest) is rejected with
/// [GcmErrorCode.invalidArgument] — never pass digests to the runtime.
({String reference, bool defaultedTag}) validateImageReference(String raw) {
  final input = raw.trim();
  if (input.isEmpty) {
    throw GcmException(GcmErrorCode.invalidArgument, '镜像引用不能为空');
  }
  if (input.contains('@') ||
      RegExp(r'^(sha256:)?[0-9a-f]{64}$').hasMatch(input)) {
    throw GcmException(
      GcmErrorCode.invalidArgument,
      '不支持 digest 寻址：$input',
      hint:
          '请改用 name:tag 形式（如 alpine:3.19）；digest 寻址在上游存在'
          '误解析风险（apple/container#1962）。',
    );
  }
  final split = splitImageReference(input);
  if (split.name.isEmpty || (split.tag != null && split.tag!.isEmpty)) {
    throw GcmException(
      GcmErrorCode.invalidArgument,
      '非法的镜像引用：$input',
      hint: '期望 name:tag 形式（如 docker.io/library/alpine:3.19）。',
    );
  }
  if (split.tag == null) {
    return (reference: '${split.name}:latest', defaultedTag: true);
  }
  return (reference: input, defaultedTag: false);
}

/// Splits a reference into name and tag. A colon BEFORE the last slash is a
/// registry port (registry:5056/name) and does not count as a tag separator.
/// [tag] is null for untagged (dangling) references as reported by the
/// runtime after a same-name rebuild.
({String name, String? tag}) splitImageReference(String reference) {
  final lastSlash = reference.lastIndexOf('/');
  final lastColon = reference.lastIndexOf(':');
  if (lastColon > lastSlash) {
    return (
      name: reference.substring(0, lastColon),
      tag: reference.substring(lastColon + 1),
    );
  }
  return (name: reference, tag: null);
}

/// One row of the image list (XPC `ClientImage.list()` → ImageDescription).
class ImageInfo {
  const ImageInfo({
    required this.reference,
    required this.name,
    required this.tag,
    this.digest,
    this.mediaType,
    this.sizeBytes,
    this.createdAt,
  });

  /// Parses a bridge payload: {reference, digest?, mediaType?, sizeBytes?,
  /// createdAt?}. Untagged images (dangling) arrive with a tag-less
  /// reference; the UI renders them as `<none>` like the upstream CLI.
  factory ImageInfo.fromMap(Map<String, Object?> map) {
    final reference = (map['reference'] as String?) ?? '';
    final split = splitImageReference(reference);
    final createdRaw = map['createdAt'] as String?;
    return ImageInfo(
      reference: reference,
      name: split.name,
      tag: split.tag,
      digest: map['digest'] as String?,
      mediaType: map['mediaType'] as String?,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt(),
      createdAt: createdRaw == null ? null : DateTime.tryParse(createdRaw),
    );
  }

  /// Full normalized reference (e.g. docker.io/library/alpine:3.19).
  final String reference;
  final String name;

  /// Null when the image is untagged (dangling).
  final String? tag;

  /// Index descriptor digest (sha256:…).
  final String? digest;
  final String? mediaType;

  /// Descriptor size in bytes. NOTE: this is the index-descriptor size
  /// upstream, not the full on-disk size; accurate sizes are computed
  /// lazily (orchard pattern). Good enough for list display.
  final int? sizeBytes;
  final DateTime? createdAt;

  bool get isDangling => tag == null;

  /// CLI-style display: `<none>` for the tag of dangling images.
  String get displayReference => isDangling ? '$name:<none>' : reference;

  /// Nulls are omitted so the map passes the MCP outputSchema validation
  /// (JsonString entries are non-nullable).
  Map<String, Object?> toJson() => <String, Object?>{
    'reference': reference,
    'name': name,
    'tag': ?tag,
    'digest': ?digest,
    'mediaType': ?mediaType,
    'sizeBytes': ?sizeBytes,
    'createdAt': ?createdAt?.toIso8601String(),
    'dangling': isDangling,
  };
}

/// Config summary of one image (`image_inspect` output): OCI image config
/// plus layer/platform counts. Rebuilt client-side from index + manifest +
/// config blobs (orchard inspect pattern).
class ImageInspection {
  const ImageInspection({
    required this.reference,
    this.digest,
    this.sizeBytes,
    this.layers = 0,
    this.platforms = const <String>[],
    this.env = const <String>[],
    this.entrypoint = const <String>[],
    this.cmd = const <String>[],
    this.exposedPorts = const <String>[],
    this.labels = const <String, String>{},
  });

  factory ImageInspection.fromMap(Map<String, Object?> map) {
    final config =
        (map['config'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return ImageInspection(
      reference: (map['reference'] as String?) ?? '',
      digest: map['digest'] as String?,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt(),
      layers: (map['layers'] as num?)?.toInt() ?? 0,
      platforms: _stringList(map['platforms']),
      env: _stringList(config['env']),
      entrypoint: _stringList(config['entrypoint']),
      cmd: _stringList(config['cmd']),
      exposedPorts: _stringList(config['exposedPorts']),
      labels:
          (config['labels'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const <String, String>{},
    );
  }

  final String reference;
  final String? digest;

  /// Full on-disk size (ClientImage.getFullImageSize), unlike the
  /// descriptor size on [ImageInfo].
  final int? sizeBytes;
  final int layers;
  final List<String> platforms;
  final List<String> env;
  final List<String> entrypoint;
  final List<String> cmd;
  final List<String> exposedPorts;
  final Map<String, String> labels;

  Map<String, Object?> toJson() => <String, Object?>{
    'reference': reference,
    'digest': digest,
    'sizeBytes': sizeBytes,
    'layers': layers,
    'platforms': platforms,
    'config': <String, Object?>{
      'env': env,
      'entrypoint': entrypoint,
      'cmd': cmd,
      'exposedPorts': exposedPorts,
      'labels': labels,
    },
  };

  static List<String> _stringList(Object? value) =>
      (value as List?)?.map((e) => e.toString()).toList(growable: false) ??
      const <String>[];
}

/// One pull-progress sample, folded upstream to ~10 Hz at the bridge (the
/// single throttle point shared by the UI event channel and MCP progress
/// notifications — docs/research/bridge-flutter-apple-container.md).
class ImagePullProgress {
  const ImagePullProgress({
    required this.pullId,
    this.description,
    this.completedBytes = 0,
    this.totalBytes,
    this.itemsDone,
    this.itemsTotal,
  });

  final String pullId;

  /// Current phase text from the runtime (e.g. 下载中/解包中 equivalents).
  final String? description;
  final int completedBytes;
  final int? totalBytes;
  final int? itemsDone;
  final int? itemsTotal;

  /// 0..1, or null while the total is unknown.
  double? get fraction => totalBytes != null && totalBytes! > 0
      ? completedBytes / totalBytes!
      : null;
}

/// Terminal outcome of a pull: completed with the pulled image, or
/// cancelled client-side (v1 semantics: there is no server-side cancel
/// route; cancelling drops the local wait).
sealed class ImagePullOutcome {
  const ImagePullOutcome();
}

class ImagePullCompleted extends ImagePullOutcome {
  const ImagePullCompleted(this.image);
  final ImageInfo image;
}

class ImagePullCancelled extends ImagePullOutcome {
  const ImagePullCancelled();
}
