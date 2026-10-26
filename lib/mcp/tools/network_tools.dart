/// MCP `network_*` tool handlers (docs/spec/mcp-tools.md §3.4) — read-only
/// network listing via CLI (`container network ls --format json`) joined
/// with container snapshot attachments.
///
/// Declarative metadata lives in lib/mcp/tool_catalog.dart (ADR-0001);
/// this module only binds handlers to registry entries.
library;

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/errors.dart';
import '../../services/network_service.dart';
import 'pagination.dart';
import 'system_tools.dart';

/// Registers the network domain tools on [service].
void registerNetworkTools(
  ToolRegistrar service,
  NetworkService networkService,
) {
  registerCatalogTool(
    service,
    'network_list',
    callback: (args, extra) => guardToolCall(() async {
      final networks = await networkService.listNetworks();
      // issue #31：稳定排序（id 升序）后统一分页。
      final sorted = List.of(networks)..sort((a, b) => a.id.compareTo(b.id));
      final page = listPageArguments(args);
      final slice = listPageSlice(
        sorted,
        limit: page.limit,
        offset: page.offset,
      );
      return (
        data: <String, Object?>{
          'networks': slice.map((n) => n.toWire()).toList(growable: false),
          ...listPageEnvelope(
            total: sorted.length,
            returned: slice.length,
            offset: page.offset,
          ),
        },
        summary:
            '共 ${sorted.length} 个网络，本页 ${slice.length} 个'
            '${listSummaryPreview(slice.map((n) => n.id))}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'network_get',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'];
      // 防御层（ADR-0002）：分发前 schema 校验已挡掉缺失/错类型；
      // 这里的业务校验保留，不删。
      if (id is! String || id.isEmpty) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          'network_get requires a non-empty "id" argument.',
        );
      }
      final detail = await networkService.getNetwork(id);
      return (
        data: detail.toWire(),
        summary: '网络 ${detail.info.id}：${detail.containers.length} 个容器接入。',
      );
    }),
  );
}
