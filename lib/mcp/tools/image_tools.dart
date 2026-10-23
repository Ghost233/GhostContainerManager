/// MCP `image_*` tools (docs/spec/mcp-tools.md §3.2 镜像域, T5 / issue #20).
///
/// image_pull is a synchronous long-operation tool: progress flows as MCP
/// progress notifications (extra.sendProgress, bridge-throttled ~10 Hz),
/// and client cancellation (extra.signal) drops the local wait via
/// ImageService.cancelPull.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/errors.dart';
import '../../services/image_models.dart';
import '../../services/image_service.dart';

/// Same two-layer error model as container_tools.dart: success carries
/// structuredContent + a Chinese text summary; failures come back as
/// CallToolResult(isError: true) with the {error:{code,message,hint?}} wire.
Future<CallToolResult> _guardImageCall(
  Future<({Map<String, Object?> data, String summary})> Function() body,
) async {
  try {
    final result = await body();
    return CallToolResult(
      content: [TextContent(text: result.summary)],
      structuredContent: result.data,
    );
  } on GcmException catch (e) {
    final wire = e.toWire();
    return CallToolResult(
      content: [TextContent(text: jsonEncode(wire))],
      isError: true,
      structuredContent: wire,
    );
  } catch (e) {
    final wire = GcmException(
      GcmErrorCode.internal,
      '未预期的内部错误',
      cause: e,
    ).toWire();
    return CallToolResult(
      content: [TextContent(text: jsonEncode(wire))],
      isError: true,
      structuredContent: wire,
    );
  }
}

/// Image tools read/write an external runtime — open world per the spec's
/// annotation contract.
const _readOnlyOpenWorld = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

const _writeOpenWorld = ToolAnnotations(
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

const _deleteOpenWorld = ToolAnnotations(
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: true,
  openWorldHint: true,
);

const _referenceDescription =
    '镜像引用，必须 name:tag（如 alpine:3.19，省略 tag 默认 :latest）。'
    '不支持 digest 寻址（apple/container#1962）。';

/// Registers the image tools on [server].
void registerImageTools(McpServer server, ImageService service) {
  server.registerTool(
    'image_list',
    title: '列出镜像',
    description:
        '列出全部镜像（reference/digest/大小/创建时间）。tag 为 null 且 '
        'dangling=true 的是未被引用的悬空镜像（同名替换构建后的旧镜像）。',
    inputSchema: JsonObject(
      properties: const <String, JsonSchema>{},
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'images': JsonArray(
          items: JsonObject(
            properties: <String, JsonSchema>{
              'reference': const JsonString(),
              'name': const JsonString(),
              'tag': const JsonString(),
              'digest': const JsonString(),
              'sizeBytes': const JsonInteger(),
              'createdAt': const JsonString(),
              'dangling': const JsonBoolean(),
            },
            required: ['reference', 'dangling'],
          ),
        ),
      },
      required: ['images'],
    ),
    annotations: _readOnlyOpenWorld,
    callback: (args, extra) => _guardImageCall(() async {
      final images = await service.listImages();
      final dangling = images.where((i) => i.isDangling).length;
      return (
        data: <String, Object?>{
          'images': images.map((i) => i.toJson()).toList(growable: false),
        },
        summary:
            '共 ${images.length} 个镜像（悬空 $dangling 个）：'
            '${images.map((i) => i.displayReference).join('、')}',
      );
    }),
  );

  server.registerTool(
    'image_inspect',
    title: '镜像配置摘要',
    description:
        '返回镜像的配置摘要：环境变量、入口命令、暴露端口、标签、层数、'
        '支持的平台与完整磁盘大小（非 descriptor 大小）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(description: _referenceDescription),
      },
      required: ['reference'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'image': JsonObject(
          properties: <String, JsonSchema>{
            'reference': const JsonString(),
            'digest': const JsonString(),
            'sizeBytes': const JsonInteger(),
            'layers': const JsonInteger(),
            'platforms': const JsonArray(),
            'config': const JsonObject(),
          },
          required: ['reference'],
        ),
      },
      required: ['image'],
    ),
    annotations: _readOnlyOpenWorld,
    callback: (args, extra) => _guardImageCall(() async {
      final inspection = await service.inspect(args['reference'] as String);
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

  server.registerTool(
    'image_delete',
    title: '删除镜像',
    description:
        '删除镜像（移除 tag；未被引用的层由运行时 GC 回收）。正被容器引用的'
        '镜像会被拒绝并列出引用它的容器（CONFLICT）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(description: _referenceDescription),
      },
      required: ['reference'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(),
        'deleted': const JsonBoolean(),
      },
      required: ['reference', 'deleted'],
    ),
    annotations: _deleteOpenWorld,
    callback: (args, extra) => _guardImageCall(() async {
      final reference = args['reference'] as String;
      await service.delete(reference);
      final normalized = validateImageReference(reference).reference;
      return (
        data: <String, Object?>{'reference': normalized, 'deleted': true},
        summary: '已删除镜像 $normalized（tag 已移除，未引用的层由 GC 回收）',
      );
    }),
  );

  server.registerTool(
    'image_pull',
    title: '拉取镜像',
    description:
        '拉取镜像到本地。长任务：通过 progress notification 汇报百分比/字节'
        '（桥接侧已折叠到 ~10Hz）；客户端取消会停止本地等待（上游无服务端'
        '取消路由，运行时可能在后台完成拉取）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(description: _referenceDescription),
        'platform': const JsonString(
          description: '目标平台（如 linux/arm64、linux/amd64），缺省为本机架构',
        ),
      },
      required: ['reference'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'reference': const JsonString(),
        'digest': const JsonString(),
        'sizeBytes': const JsonInteger(),
      },
      required: ['reference'],
    ),
    annotations: _writeOpenWorld,
    callback: (args, extra) => _guardImageCall(() async {
      final pullId = service.newPullId();
      final abortSub = extra.signal.onAbort.listen((_) {
        unawaited(service.cancelPull(pullId));
      });
      try {
        final outcome = await service.pull(
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
