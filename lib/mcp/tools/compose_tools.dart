/// MCP `compose_*` tool handlers (docs/spec/mcp-tools.md §3.5) — orchard
/// compose plugin passthrough (up/down) plus label-aggregated project
/// listing.
///
/// The plugin emits human text, never JSON → up/down pass the raw output
/// through verbatim (tail-truncated to the service cap).
///
/// Declarative metadata lives in lib/mcp/tool_catalog.dart (ADR-0001);
/// this module only binds handlers to registry entries.
library;

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/compose_service.dart';
import '../../services/errors.dart';
import 'pagination.dart';
import 'system_tools.dart';

/// Registers the compose domain tools on [service].
void registerComposeTools(
  ToolRegistrar service,
  ComposeService composeService,
) {
  registerCatalogTool(
    service,
    'compose_list',
    callback: (args, extra) => guardToolCall(() async {
      final projects = await composeService.listProjects();
      // issue #31：稳定排序（项目名升序）后统一分页。
      final sorted = List.of(projects)
        ..sort((a, b) => a.name.compareTo(b.name));
      final page = listPageArguments(args);
      final slice = listPageSlice(
        sorted,
        limit: page.limit,
        offset: page.offset,
      );
      return (
        data: <String, Object?>{
          'projects': slice.map((p) => p.toWire()).toList(growable: false),
          ...listPageEnvelope(
            total: sorted.length,
            returned: slice.length,
            offset: page.offset,
          ),
        },
        summary:
            '共 ${sorted.length} 个 Compose 项目，本页 ${slice.length} 个'
            '${listSummaryPreview(slice.map((p) => p.name))}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'compose_up',
    callback: (args, extra) => guardToolCall(() async {
      final file = args['file'];
      // 防御层（ADR-0002）：分发前 schema 校验已挡掉缺失/错类型；
      // 这里的业务校验保留，不删。
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

  registerCatalogTool(
    service,
    'compose_down',
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
