/// Image domain service (T5, issue #20): list/inspect/delete/pull built on
/// the image-domain bridge seam.
///
/// Addressing contract: every entry point validates `name:tag` via
/// [validateImageReference] (digest addressing rejected, #1962) BEFORE the
/// reference crosses the bridge. The delete in-use pre-check lives here
/// (Service-layer semantics, unit-testable) because it produces a clearer
/// error than the upstream refusal.
library;

// 公共命名参数（bridge、containerService）保持可见名；与 container_service
// 一致关闭该 lint。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../bridge/container_bridge.dart';
import 'container_service.dart';
import 'errors.dart';
import 'image_models.dart';

class ImageService {
  ImageService({
    required ContainerBridge bridge,
    ContainerService? containerService,
  }) : _bridge = bridge,
       _containerService = containerService;

  final ContainerBridge _bridge;

  /// Used only for the delete in-use pre-check. When null (e.g. minimal
  /// wiring), the pre-check is skipped and the upstream error passes
  /// through [mapImageFailure] instead.
  final ContainerService? _containerService;

  int _pullCounter = 0;

  /// Fresh unfiltered image list, parsed and typed.
  Future<List<ImageInfo>> listImages() async {
    try {
      final raw = await _bridge.imageList();
      return raw.map(ImageInfo.fromMap).toList(growable: false);
    } on BridgeCallException catch (e) {
      throw mapImageFailure(e, operation: 'list');
    }
  }

  /// Config summary of one image (index + manifest + config rebuild).
  Future<ImageInspection> inspect(String reference) async {
    final parsed = validateImageReference(reference);
    try {
      return ImageInspection.fromMap(
        await _bridge.imageInspect(parsed.reference),
      );
    } on BridgeCallException catch (e) {
      throw mapImageFailure(
        e,
        operation: 'inspect',
        reference: parsed.reference,
      );
    }
  }

  /// Deletes [reference] (tag removal; blob GC is upstream's business).
  ///
  /// In-use semantics (#20 验收 3): when a [ContainerService] is wired,
  /// images referenced by ANY container are refused up front with
  /// [GcmErrorCode.conflict] naming the referencing containers — clearer
  /// than the upstream error. Without one, the upstream refusal is mapped.
  Future<void> delete(String reference) async {
    final parsed = validateImageReference(reference);
    final users = await containersUsing(parsed.reference);
    if (users.isNotEmpty) {
      throw GcmException(
        GcmErrorCode.conflict,
        '镜像 ${parsed.reference} 正被 ${users.length} 个容器引用：'
        '${users.join('、')}',
        hint: '先删除这些容器，或改用项目回收（project_reclaim）处理。',
      );
    }
    try {
      await _bridge.imageDelete(parsed.reference);
    } on BridgeCallException catch (e) {
      throw mapImageFailure(
        e,
        operation: 'delete',
        reference: parsed.reference,
      );
    }
  }

  /// Ids of containers whose configured image matches [reference] exactly.
  /// Returns empty when no [ContainerService] is wired.
  Future<List<String>> containersUsing(String reference) async {
    final containers = _containerService;
    if (containers == null) return const <String>[];
    final all = await containers.listContainers(const ContainerQuery());
    return all
        .where((c) => c.image == reference)
        .map((c) => c.id)
        .toList(growable: false);
  }

  /// Generates a fresh pull id for [pull] / [cancelPull].
  String newPullId() =>
      'pull-${++_pullCounter}-${DateTime.now().microsecondsSinceEpoch}';

  /// Pulls [reference] (validated name:tag; tag-less input defaults to
  /// `:latest`). [onProgress] receives bridge-throttled (~10 Hz) samples;
  /// pass a [pullId] from [newPullId] so [cancelPull] can target it.
  ///
  /// Cancel semantics (v1): [cancelPull] drops the local wait and this
  /// method completes with [ImagePullCancelled]; the runtime may finish
  /// the pull in the background (no server-side cancel route upstream).
  Future<ImagePullOutcome> pull({
    required String reference,
    String? platform,
    String? pullId,
    void Function(ImagePullProgress progress)? onProgress,
  }) async {
    final parsed = validateImageReference(reference);
    final id = pullId ?? newPullId();
    StreamSubscription<BridgeImagePullEvent>? sub;
    if (onProgress != null) {
      sub = _bridge.imagePullEvents().where((e) => e.pullId == id).listen((
        event,
      ) {
        onProgress(
          ImagePullProgress(
            pullId: id,
            description: event.description,
            completedBytes: event.completedBytes,
            totalBytes: event.totalBytes,
            itemsDone: event.itemsDone,
            itemsTotal: event.itemsTotal,
          ),
        );
      });
    }
    try {
      final result = await _bridge.imagePull(
        pullId: id,
        reference: parsed.reference,
        platform: platform,
      );
      if (result['cancelled'] == true) {
        return const ImagePullCancelled();
      }
      return ImagePullCompleted(ImageInfo.fromMap(result));
    } on BridgeCallException catch (e) {
      throw mapImageFailure(e, operation: 'pull', reference: parsed.reference);
    } finally {
      await sub?.cancel();
    }
  }

  /// Cancels the local wait for [pullId] (see [pull] for v1 semantics).
  Future<void> cancelPull(String pullId) => _bridge.imagePullCancel(pullId);
}

/// Feature-fingerprint classification of raw bridge error text for the
/// image domain (same approach as `mapContainerFailure`).
GcmException mapImageFailure(
  BridgeCallException error, {
  required String operation,
  String? reference,
}) {
  final message = error.message;
  final lower = message.toLowerCase();

  if (lower.contains('connection invalid') ||
      lower.contains('xpc connection')) {
    return GcmException(
      GcmErrorCode.runtimeUnavailable,
      '容器运行时不可达，无法$operation镜像。',
      hint: '先在「运行时」页启动服务（system.start）。',
      cause: error,
    );
  }
  if (lower.contains('failed to decode')) {
    return GcmException(
      GcmErrorCode.versionMismatch,
      '镜像 $operation 时运行时返回了无法识别的数据格式。',
      hint: '请在设置中核对 container 版本（期望 1.6.x）。',
      cause: error,
    );
  }
  if (lower.contains('permission denied')) {
    return GcmException(
      GcmErrorCode.permissionDenied,
      '镜像 $operation 权限不足。',
      cause: error,
    );
  }
  if (lower.contains('not found') || lower.contains('does not exist')) {
    return GcmException(
      GcmErrorCode.notFound,
      '镜像 ${reference ?? ''} 不存在。',
      hint: operation == 'pull' ? '核对 name:tag 是否拼写正确。' : '列表可能已过期，请刷新。',
      cause: error,
    );
  }
  if (lower.contains('in use') || lower.contains('referenced')) {
    return GcmException(
      GcmErrorCode.conflict,
      '镜像 ${reference ?? ''} 正被容器引用，无法删除。',
      hint: '先删除引用它的容器。',
      cause: error,
    );
  }
  return GcmException(
    GcmErrorCode.internal,
    '镜像 $operation 失败：$message',
    cause: error,
  );
}
