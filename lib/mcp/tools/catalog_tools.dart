/// Slim MCP surface: `gcm_help` + `gcm_call`（精简注册模式）。
///
/// 2026-10-26 用户拍板：35 个业务工具不再逐个注册到 tools/list（工具
/// 列表太长），改为只暴露两个入口工具——`gcm_help` 返回按域分组的工具
/// 目录（名称/描述/参数要点/风险注解），`gcm_call` 按名分发到业务工具的
/// 原有 callback。业务工具的实现与测试不变，只是注册目标从 McpServer
/// 换成 [ToolCallbackRegistry]。
///
/// issue #29 / ADR-0001：工具目录的单一事实来源是
/// lib/mcp/tool_catalog.dart 的声明式注册表；ADR-0002：`gcm_call` 在调
/// handler 前用 mcp_dart 内建校验器（JsonSchemaValidation）按注册表
/// inputSchema 校验业务参数，失败返回 INVALID_ARGUMENT 且 handler
/// 不执行。
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
      // 目录成员来自 ToolCallbackRegistry 的注册快照（只含实际接线的
      // 工具）；渲染数据仍取自主注册表条目，元数据单一事实来源不变。
      final grouped = <String, List<ToolCatalogEntry>>{};
      for (final name in businessTools.tools.keys) {
        final entry = catalogEntryByName(name);
        // registerCatalogTool 对未知名直接抛错，这里不可能为空。
        if (entry == null) continue;
        grouped
            .putIfAbsent(entry.domain, () => <ToolCatalogEntry>[])
            .add(entry);
      }
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
      // issue #31：structuredContent 保留完整目录，文本通道降级为一行摘要，
      // 不再内嵌整份 JSON。
      final domainCounts = domains.entries
          .map((e) => '${e.key}(${(e.value as List).length})')
          .join('、');
      final summary = domains.isEmpty
          ? '共 0 个工具'
          : '共 $total 个工具（${domains.length} 个域）：$domainCounts';
      return CallToolResult(
        content: [
          TextContent(
            text: 'GCM 工具目录：$summary。调用方式：gcm_call({tool, arguments})。',
          ),
        ],
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
      final definition = businessTools.tools[tool];
      if (definition == null) {
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
      // ADR-0002 分发前校验：用注册快照里的 inputSchema（即注册表条目
      // 声明的 schema）+ mcp_dart 内建校验器（JsonSchemaValidation，
      // draft 2020-12）校验业务参数；失败时 handler 不得执行。业务特有
      // 限制（非空命令、绝对路径、project/path 选择规则）仍由 handler
      // 内紧邻的业务校验负责。
      final inputSchema = definition.inputSchema;
      if (inputSchema != null) {
        try {
          inputSchema.validate(toolArgs);
        } on JsonSchemaValidationException catch (error) {
          final where = error.path.isEmpty
              ? ''
              : '（字段 ${error.path.join('/')}）';
          return _catalogError(
            GcmErrorCode.invalidArgument,
            '工具 $tool 的参数未通过 schema 校验$where：${error.message}',
            hint: '先调用 gcm_help 查看 $tool 的参数定义后修正调用。',
          );
        }
      }
      // extra 原样透传（issue #32 长任务核对）：长任务工具会消费
      // RequestHandlerExtra——image_pull / project_build / project_test /
      // project_publish / project_restore / registry_start 读
      // extra.signal（取消）与 extra.sendProgress（依赖
      // extra.meta['progressToken']）。原样透传保证 gcm_call 请求上的
      // cancelled 通知与 _meta.progressToken 直接作用于业务工具。核对
      // 结论与已知限制见 test/mcp/long_task_semantics_test.dart 的文件
      // 头注释。
      return definition.callback(toolArgs, extra);
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
