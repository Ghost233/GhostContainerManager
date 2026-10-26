/// MCP `image_*` tool handlers (docs/spec/mcp-tools.md §3.2 镜像域, T5 /
/// issue #20).
///
/// image_pull is a synchronous long-operation tool: progress flows as MCP
/// progress notifications (extra.sendProgress, bridge-throttled ~10 Hz),
/// and client cancellation (extra.signal) drops the local wait via
/// ImageService.cancelPull.
///
/// Declarative metadata lives in lib/mcp/tool_catalog.dart (ADR-0001);
/// this module only binds handlers to registry entries.
library;

import 'dart:async';

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/errors.dart';
import '../../services/image_models.dart';
import '../../services/image_service.dart';
import 'pagination.dart';
import 'system_tools.dart';

/// Registers the image tools on [service].
void registerImageTools(ToolRegistrar service, ImageService imageService) {
  registerCatalogTool(
    service,
    'image_list',
    callback: (args, extra) => guardToolCall(() async {
      final images = await imageService.listImages();
      // issue #31：稳定排序（reference 升序）后统一分页。
      final sorted = List.of(images)
        ..sort((a, b) => a.displayReference.compareTo(b.displayReference));
      final dangling = sorted.where((i) => i.isDangling).length;
      final page = listPageArguments(args);
      final slice = listPageSlice(
        sorted,
        limit: page.limit,
        offset: page.offset,
      );
      return (
        data: <String, Object?>{
          'images': slice.map((i) => i.toJson()).toList(growable: false),
          ...listPageEnvelope(
            total: sorted.length,
            returned: slice.length,
            offset: page.offset,
          ),
        },
        summary:
            '共 ${sorted.length} 个镜像（悬空 $dangling 个），本页 ${slice.length} 个'
            '${listSummaryPreview(slice.map((i) => i.displayReference))}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'image_inspect',
    callback: (args, extra) => guardToolCall(() async {
      final inspection = await imageService.inspect(
        args['reference'] as String,
      );
      return (
        data: <String, Object?>{'image': inspection.toJson()},
        summary:
            '镜像 ${inspection.reference}：${inspection.layers} 层，'
            '平台 ${inspection.platforms.join('、')}，'
            '环境变量 ${inspection.env.length} 项，'
            '入口 ${(inspection.entrypoint + inspection.cmd).join(' ')}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'image_delete',
    callback: (args, extra) => guardToolCall(() async {
      final reference = args['reference'] as String;
      await imageService.delete(reference);
      final normalized = validateImageReference(reference).reference;
      return (
        data: <String, Object?>{'reference': normalized, 'deleted': true},
        summary: '已删除镜像 $normalized（tag 已移除，未引用的层由 GC 回收）',
      );
    }),
  );

  registerCatalogTool(
    service,
    'image_pull',
    callback: (args, extra) => guardToolCall(() async {
      final pullId = imageService.newPullId();
      final abortSub = extra.signal.onAbort.listen((_) {
        unawaited(imageService.cancelPull(pullId));
      });
      try {
        final outcome = await imageService.pull(
          reference: args['reference'] as String,
          platform: args['platform'] as String?,
          pullId: pullId,
          onProgress: (progress) {
            unawaited(
              extra.sendProgress(
                progress.fraction ?? 0,
                total: 1,
                message:
                    progress.description ?? '${progress.completedBytes} 字节已拉取',
              ),
            );
          },
        );
        switch (outcome) {
          case ImagePullCompleted(:final image):
            return (
              data: <String, Object?>{
                'reference': image.reference,
                'digest': image.digest,
                'sizeBytes': image.sizeBytes,
              },
              summary: '已拉取镜像 ${image.reference}（${image.digest ?? '-'}）',
            );
          case ImagePullCancelled():
            // Client-aborted pulls never see this result; a local cancel
            // surfaces as an explicit error.
            extra.signal.throwIfAborted();
            throw GcmException(
              GcmErrorCode.internal,
              '镜像拉取已取消',
              hint: '拉取未落盘完成；可重新发起 image_pull。',
            );
        }
      } finally {
        await abortSub.cancel();
      }
    }),
  );
}
