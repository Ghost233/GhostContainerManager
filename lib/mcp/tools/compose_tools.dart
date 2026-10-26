/// MCP `compose_*` tools (docs/spec/mcp-tools.md §3.5) — orchard compose
/// plugin passthrough (up/down) plus label-aggregated project listing.
///
/// The plugin emits human text, never JSON → up/down pass the raw output
/// through verbatim (tail-truncated to the service cap).
library;

import 'package:mcp_dart/mcp_dart.dart';

import '../tool_registrar.dart';

import '../../services/compose_service.dart';
import '../../services/errors.dart';
import 'system_tools.dart';

/// Registers the compose domain tools on [service].
void registerComposeTools(
  ToolRegistrar service,
  ComposeService composeService,
) {
  service.registerTool(
    'compose_list',
    title: 'List Compose Projects',
    description:
        '按容器 label（com.compose.project / com.compose.service）聚合当前存在的 '
        'Compose 项目：项目名、服务清单、各服务对应容器与状态。'
        '插件只提供 up/down，项目发现走 label 聚合（不需要插件也可工作）。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'projects': const JsonArray()},
      required: ['projects'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final projects = await composeService.listProjects();
      return (
        data: <String, Object?>{
          'projects': projects.map((p) => p.toWire()).toList(growable: false),
        },
        summary: '共 ${projects.length} 个 Compose 项目。',
      );
    }),
  );

  service.registerTool(
    'compose_up',
    title: 'Compose Up',
    description:
        '运行 container compose up（需要本机已安装 compose 插件；未安装时返回'
        ' NOT_FOUND 与安装指引）。file 必须是绝对路径。输出为插件的人类可读文本'
        '原样透传（超长时保留尾部并标记 truncated）。'
        '可用 dryRun 只打印计划不改动任何资源。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'file': JsonString(description: 'compose 文件绝对路径'),
        'projectName': JsonString(description: '项目名（缺省取文件 name 或目录名）'),
        'dryRun': JsonBoolean(
          description: '只计算并打印计划，不创建/修改资源',
          defaultValue: false,
        ),
        'forceRecreate': JsonBoolean(
          description: '强制重建所有服务容器',
          defaultValue: false,
        ),
        'pull': JsonString(
          description: '镜像拉取策略',
          enumValues: ['missing', 'always', 'never'],
          defaultValue: 'missing',
        ),
      },
      required: ['file'],
      additionalProperties: false,
    ),
    outputSchema: _composeRunOutput(),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final file = args['file'];
      if (file is! String || file.isEmpty) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          'compose_up requires a non-empty "file" argument.',
        );
      }
      final result = await composeService.up(
        file: file,
        projectName: args['projectName'] as String?,
        dryRun: args['dryRun'] == true,
        forceRecreate: args['forceRecreate'] == true,
        pull: args['pull'] as String? ?? 'missing',
      );
      return (
        data: result.toWire(),
        summary:
            'compose up 完成（exit ${result.exitCode}）'
            '${result.truncated ? '，输出已截断' : ''}。',
      );
    }),
  );

  service.registerTool(
    'compose_down',
    title: 'Compose Down',
    description:
        '运行 container compose down，停止并移除项目的容器与其创建的网络'
        '（keepNetworks 可保留网络）。file 与 projectName 至少提供一项；'
        '输出为人类可读文本原样透传。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'file': JsonString(description: 'compose 文件绝对路径（与 projectName 至少一项）'),
        'projectName': JsonString(description: '项目名（与 file 至少一项）'),
        'keepNetworks': JsonBoolean(
          description: '保留项目创建的网络',
          defaultValue: false,
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: _composeRunOutput(),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: true,
      openWorldHint: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final result = await composeService.down(
        file: args['file'] as String?,
        projectName: args['projectName'] as String?,
        keepNetworks: args['keepNetworks'] == true,
      );
      return (
        data: result.toWire(),
        summary:
            'compose down 完成（exit ${result.exitCode}）'
            '${result.truncated ? '，输出已截断' : ''}。',
      );
    }),
  );
}

JsonObject _composeRunOutput() => const JsonObject(
  properties: <String, JsonSchema>{
    'exitCode': JsonInteger(),
    'output': JsonString(),
    'truncated': JsonBoolean(),
  },
  required: ['exitCode', 'output', 'truncated'],
  additionalProperties: false,
);
