/// Slim MCP surface: `gcm_help` + `gcm_call`（精简注册模式）。
///
/// 2026-10-26 用户拍板：35 个业务工具不再逐个注册到 tools/list（工具
/// 列表太长），改为只暴露两个入口工具——`gcm_help` 返回按域分组的工具
/// 目录（名称/描述/参数要点/风险注解），`gcm_call` 按名分发到业务工具的
/// 原有 callback。业务工具的实现与测试不变，只是注册目标从 McpServer
/// 换成 [ToolCallbackRegistry]。
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/compose_service.dart';
import '../../services/container_service.dart';
import '../../services/errors.dart';
import '../../services/image_service.dart';
import '../../services/mount_service.dart';
import '../../services/network_service.dart';
import '../../services/project_service.dart';
import '../../services/registry_service.dart';
import '../../services/system_service.dart';
import '../tool_catalog.dart';
import '../tool_registrar.dart';
import 'compose_tools.dart';
import 'container_tools.dart';
import 'image_tools.dart';
import 'mount_tools.dart';
import 'network_tools.dart';
import 'project_tools.dart';
import 'registry_tools.dart';
import 'system_tools.dart';

/// Builds the name → callback dispatch table for all business tools whose
/// backing service is available. Mirrors the conditional registration in
/// `GcmMcpServer.buildServer` (null service = domain not wired).
ToolCallbackRegistry buildBusinessToolRegistry({
  required SystemService systemService,
  required ContainerService containerService,
  ImageService? imageService,
  MountService? mountService,
  NetworkService? networkService,
  ComposeService? composeService,
  ProjectService? projectService,
  RegistryService? registryService,
}) {
  final registry = ToolCallbackRegistry();
  registerSystemTools(registry, systemService);
  registerContainerTools(registry, containerService);
  final image = imageService;
  if (image != null) registerImageTools(registry, image);
  final mount = mountService;
  if (mount != null) registerMountTools(registry, mount);
  final network = networkService;
  if (network != null) registerNetworkTools(registry, network);
  final compose = composeService;
  if (compose != null) registerComposeTools(registry, compose);
  final project = projectService;
  if (project != null) registerProjectTools(registry, project);
  final registrySvc = registryService;
  if (registrySvc != null) registerRegistryTools(registry, registrySvc);
  return registry;
}

const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
);

/// Registers the two slim entry tools on [server].
void registerCatalogTools(
  McpServer server,
  ToolCallbackRegistry businessTools,
) {
  server.registerTool(
    'gcm_help',
    title: 'List GCM Tools',
    description:
        '列出本应用提供的全部容器管理工具（按域分组，含参数要点与风险注解）。'
        '先用本工具找到目标工具名与参数，再通过 gcm_call 调用。'
        '可选参数 domain 过滤单个域（system/container/image/mount/network/compose/project/registry）。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'domain': const JsonString(
          description: '只返回该域的工具',
          enumValues: [
            'system',
            'container',
            'image',
            'mount',
            'network',
            'compose',
            'project',
            'registry',
          ],
        ),
      },
      additionalProperties: false,
    ),
    annotations: _readOnly,
    callback: (args, extra) async {
      final domain = args['domain'] as String?;
      final grouped = catalogByDomain();
      final domains = <String, Object?>{};
      var total = 0;
      for (final entry in grouped.entries) {
        if (domain != null && entry.key != domain) continue;
        domains[entry.key] = entry.value
            .map((t) => t.toJson())
            .toList(growable: false);
        total += entry.value.length;
      }
      final result = <String, Object?>{
        'usage':
            '调用方式：gcm_call({tool: "<工具名>", arguments: {...}})。'
            'destructiveHint=true 的工具请先与用户确认。',
        'totalTools': total,
        'domains': domains,
      };
      return CallToolResult(
        content: [TextContent(text: jsonEncode(result))],
        structuredContent: result,
      );
    },
  );

  server.registerTool(
    'gcm_call',
    title: 'Call GCM Tool',
    description:
        '按名调用一个业务工具（工具名与参数见 gcm_help 输出）。'
        '参数 tool 为工具名（如 container_list），arguments 为该工具的参数对象。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'tool': const JsonString(description: '业务工具名，见 gcm_help'),
        'arguments': const JsonObject(description: '该工具的参数对象'),
      },
      required: ['tool'],
      additionalProperties: false,
    ),
    annotations: const ToolAnnotations(
      title: 'Call GCM Tool',
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: true,
    ),
    callback: (args, extra) async {
      final tool = args['tool'] as String?;
      if (tool == null || tool.isEmpty) {
        return _catalogError(
          GcmErrorCode.invalidArgument,
          'gcm_call requires a non-empty "tool" argument.',
          hint: '先调用 gcm_help 查看可用工具名。',
        );
      }
      final callback = businessTools.callbacks[tool];
      if (callback == null) {
        return _catalogError(
          GcmErrorCode.notFound,
          '未知工具：$tool',
          hint: '先调用 gcm_help 查看可用工具名。',
        );
      }
      final rawArgs = args['arguments'];
      final toolArgs = switch (rawArgs) {
        null => <String, dynamic>{},
        Map() => Map<String, dynamic>.from(rawArgs),
        _ => null,
      };
      if (toolArgs == null) {
        return _catalogError(
          GcmErrorCode.invalidArgument,
          'gcm_call 的 arguments 必须是对象。',
        );
      }
      // 业务工具 callback 只读取 args，不触碰 RequestHandlerExtra 的
      // transport 字段（signal/sessionId/sendRequest 等），因此这里可以
      // 原样透传 gcm_call 收到的 extra。
      return callback(toolArgs, extra);
    },
  );
}

CallToolResult _catalogError(
  GcmErrorCode code,
  String message, {
  String? hint,
}) {
  final wire = GcmException(code, message, hint: hint).toWire();
  return CallToolResult(
    content: [TextContent(text: jsonEncode(wire))],
    isError: true,
    structuredContent: wire,
  );
}
