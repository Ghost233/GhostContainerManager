/// MCP `project_*` tool handlers (docs/spec/mcp-tools.md §3.6).
///
/// Curated project workflows. Runtime mutations stay in ProjectService; this
/// module only translates MCP arguments, progress, cancellation and
/// summaries. Declarative metadata (selector/input/output schemas,
/// annotations) lives in lib/mcp/tool_catalog.dart (ADR-0001).
library;

import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/project_service.dart';
import 'pagination.dart';
import 'system_tools.dart';

/// Curated project workflows. Runtime mutations stay in ProjectService; this
/// module only translates MCP schemas, progress, cancellation and summaries.
void registerProjectTools(
  ToolRegistrar service,
  ProjectService projectService,
) {
  registerCatalogTool(
    service,
    'project_list',
    callback: (args, extra) => guardToolCall(() async {
      final projects = await projectService.listProjects();
      // issue #31：稳定排序（project 名升序）后统一分页。
      final sorted = List.of(projects)
        ..sort((a, b) => a.project.compareTo(b.project));
      final page = listPageArguments(args);
      final slice = listPageSlice(
        sorted,
        limit: page.limit,
        offset: page.offset,
      );
      return (
        data: <String, Object?>{
          'projects': slice
              .map((project) => project.toJson())
              .toList(growable: false),
          ...listPageEnvelope(
            total: sorted.length,
            returned: slice.length,
            offset: page.offset,
          ),
        },
        summary:
            '共 ${sorted.length} 个项目，本页 ${slice.length} 个'
            '${listSummaryPreview(slice.map((p) => p.project))}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_get',
    callback: (args, extra) => guardToolCall(() async {
      final result = await projectService.getProject(
        project: args['project'] as String?,
        path: args['path'] as String?,
      );
      return (
        data: result.toJson(),
        summary:
            '项目 ${result.project}：${result.images.length} 个镜像，${result.containers.length} 个容器',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_init',
    callback: (args, extra) => guardToolCall(() async {
      final result = await projectService.initProject(
        path: args['path'] as String,
        prefix: args['prefix'] as String?,
      );
      return (
        data: result.toJson(),
        summary: '已在 ${result.path} 初始化项目 ${result.prefix}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_build',
    callback: (args, extra) => guardToolCall(() async {
      final buildArgs =
          (args['buildArgs'] as Map?)?.map(
            (key, value) => MapEntry(key as String, value as String),
          ) ??
          const <String, String>{};
      final result = await _withCancellation(extra, (cancellation) {
        var lines = 0;
        return projectService.buildProject(
          project: args['project'] as String?,
          path: args['path'] as String?,
          name: args['name'] as String,
          dockerfile: args['dockerfile'] as String?,
          context: args['context'] as String?,
          buildArgs: buildArgs,
          skipTests: args['skipTests'] as bool? ?? true,
          noCache: args['noCache'] as bool? ?? false,
          cancellation: cancellation,
          onProgress: (line) {
            lines += 1;
            _sendProgress(extra, lines.toDouble(), message: line);
          },
        );
      });
      final data = result.toJson();
      if (result.failureLogPath != null) {
        data['failureLogPath'] = result.failureLogPath;
      }
      return (
        data: data,
        summary: result.exitCode == 0
            ? '项目 ${result.project} 镜像 ${result.image} 构建完成'
            : '项目 ${result.project} 构建失败（exit ${result.exitCode}）',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_test',
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(
        extra,
        (cancellation) => projectService.testProject(
          project: args['project'] as String?,
          path: args['path'] as String?,
          name: args['name'] as String,
          command: (args['command'] as List).cast<String>(),
          cancellation: cancellation,
        ),
      );
      return (
        data: result.toJson(),
        summary: result.testsPassed
            ? '项目 ${result.project} 测试通过'
            : '项目 ${result.project} 测试失败（exit ${result.exitCode}）',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_reclaim',
    callback: (args, extra) => guardToolCall(() async {
      final result = await projectService.reclaimProject(
        project: args['project'] as String?,
        path: args['path'] as String?,
        dryRun: args['dryRun'] as bool? ?? false,
        force: args['force'] as bool? ?? true,
      );
      return (
        data: result.toJson(),
        summary:
            '项目 ${result.project} 回收：删除 ${result.deletedContainers.length} 个容器、'
            '${result.deletedImages.length} 个镜像，释放 ${result.disk.reclaimedBytes} 字节',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_publish',
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(extra, (cancellation) {
        var lines = 0;
        return projectService.publishProject(
          project: args['project'] as String?,
          path: args['path'] as String?,
          name: args['name'] as String,
          deleteLocal: args['deleteLocal'] as bool? ?? false,
          cancellation: cancellation,
          onProgress: (line) {
            lines += 1;
            _sendProgress(extra, lines.toDouble(), message: line);
          },
        );
      });
      return (
        data: result.toJson(),
        summary: '项目 ${result.project} 已推送 ${result.pushed.length} 个镜像',
      );
    }),
  );

  registerCatalogTool(
    service,
    'project_restore',
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(extra, (cancellation) {
        var lines = 0;
        return projectService.restoreProject(
          project: args['project'] as String?,
          path: args['path'] as String?,
          name: args['name'] as String,
          cancellation: cancellation,
          onProgress: (line) {
            lines += 1;
            _sendProgress(extra, lines.toDouble(), message: line);
          },
        );
      });
      return (
        data: result.toJson(),
        summary: '项目 ${result.project} 已恢复 ${result.restored.length} 个镜像',
      );
    }),
  );
}

Future<T> _withCancellation<T>(
  RequestHandlerExtra extra,
  Future<T> Function(Stream<void> cancellation) operation,
) async {
  final cancellation = StreamController<void>();
  final abortSubscription = extra.signal.onAbort.listen((_) {
    if (!cancellation.isClosed) cancellation.add(null);
  });
  try {
    return await operation(cancellation.stream);
  } finally {
    await abortSubscription.cancel();
    // StreamController.close() waits for a listener that may never have been
    // attached (short operations do not need to subscribe to cancellation).
    unawaited(cancellation.close());
  }
}

void _sendProgress(
  RequestHandlerExtra extra,
  double progress, {
  double? total,
  String? message,
}) {
  if (extra.meta?['progressToken'] == null) return;
  try {
    unawaited(
      extra
          .sendProgress(progress, total: total, message: message)
          .catchError((Object _) {}),
    );
  } on StateError {
    // A notification can race client disconnect; the operation still finishes.
  }
}
