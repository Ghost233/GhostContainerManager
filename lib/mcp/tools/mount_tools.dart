/// MCP `mount_*` tool handlers (docs/spec/mcp-tools.md §3.4) — read-only
/// mount aggregation. Apple container has no volume primitive; mounts are
/// container config aggregated by host source path.
///
/// Declarative metadata lives in lib/mcp/tool_catalog.dart (ADR-0001);
/// this module only binds handlers to registry entries.
library;

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/errors.dart';
import '../../services/mount_service.dart';
import 'pagination.dart';
import 'system_tools.dart';

/// Registers the mount domain tools on [service].
void registerMountTools(ToolRegistrar service, MountService mountService) {
  registerCatalogTool(
    service,
    'mount_list',
    callback: (args, extra) => guardToolCall(() async {
      final mounts = await mountService.listMounts();
      // issue #31：稳定排序（name 即主机源路径，升序）后统一分页。
      final sorted = List.of(mounts)..sort((a, b) => a.name.compareTo(b.name));
      final used = sorted.fold<int>(0, (sum, m) => sum + m.usedBy.length);
      final page = listPageArguments(args);
      final slice = listPageSlice(
        sorted,
        limit: page.limit,
        offset: page.offset,
      );
      return (
        data: <String, Object?>{
          'mounts': slice.map((m) => m.toWire()).toList(growable: false),
          ...listPageEnvelope(
            total: sorted.length,
            returned: slice.length,
            offset: page.offset,
          ),
        },
        summary:
            '共 ${sorted.length} 个挂载源，被引用 $used 次，本页 ${slice.length} 个'
            '${listSummaryPreview(slice.map((m) => m.name))}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'mount_inspect',
    callback: (args, extra) => guardToolCall(() async {
      final name = args['name'];
      // 防御层（ADR-0002）：分发前 schema 校验已挡掉缺失/错类型；
      // 这里的业务校验保留，不删。
      if (name is! String || name.isEmpty) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          'mount_inspect requires a non-empty "name" argument.',
        );
      }
      final mount = await mountService.inspectMount(name);
      return (
        data: mount.toWire(),
        summary:
            '挂载 ${mount.name}（${mount.type}）：'
            '${mount.usedBy.length} 个容器使用。',
      );
    }),
  );
}
