import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/project_service.dart';
import 'system_tools.dart';

const _prefixPattern = r'^[a-z0-9][a-z0-9.-]{0,126}$';

/// Curated project workflows. Runtime mutations stay in ProjectService; this
/// module only translates MCP schemas, progress, cancellation and summaries.
void registerProjectTools(McpServer server, ProjectService service) {
  server.registerTool(
    'project_list',
    title: 'List Projects',
    description: '列出容器 label 与 ghostcontainer.toml 发现的项目。',
    inputSchema: JsonObject(additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'projects': const JsonArray(items: JsonObject()),
      },
      required: ['projects'],
    ),
    annotations: _annotations(
      'List Projects',
      readOnly: true,
      idempotent: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final projects = await service.listProjects();
      return (
        data: <String, Object?>{
          'projects': projects
              .map((project) => project.toJson())
              .toList(growable: false),
        },
        summary: '共 ${projects.length} 个项目',
      );
    }),
  );

  server.registerTool(
    'project_get',
    title: 'Get Project',
    description: '返回项目镜像、容器与使用状态；project 与 path 二选一。',
    inputSchema: _selectorInput(),
    outputSchema: _projectDetailsOutput(),
    annotations: _annotations('Get Project', readOnly: true, idempotent: true),
    callback: (args, extra) => guardToolCall(() async {
      final result = await service.getProject(
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

  server.registerTool(
    'project_init',
    title: 'Init Project',
    description: '在项目目录创建仅含 prefix 的 ghostcontainer.toml。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'path': const JsonString(description: '项目目录'),
        'prefix': const JsonString(
          description: '项目前缀；默认使用目录名',
          pattern: _prefixPattern,
        ),
      },
      required: ['path'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'path': const JsonString(),
        'prefix': const JsonString(),
      },
      required: ['path', 'prefix'],
    ),
    annotations: _annotations('Init Project'),
    callback: (args, extra) => guardToolCall(() async {
      final result = await service.initProject(
        path: args['path'] as String,
        prefix: args['prefix'] as String?,
      );
      return (
        data: result.toJson(),
        summary: '已在 ${result.path} 初始化项目 ${result.prefix}',
      );
    }),
  );

  server.registerTool(
    'project_build',
    title: 'Build Project Image',
    description:
        '构建 {prefix}-{name}:latest。MCP 默认跳过测试；'
        '显式测试使用 project_test 的 command。失败返回末50行与持久日志路径。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(
          description: '镜像自定义名，不含项目前缀或 tag',
          pattern: _prefixPattern,
        ),
        'dockerfile': const JsonString(),
        'context': const JsonString(),
        'buildArgs': const JsonObject(additionalProperties: JsonString()),
        'skipTests': const JsonBoolean(defaultValue: true),
        'noCache': const JsonBoolean(defaultValue: false),
      },
      required: ['name'],
    ),
    outputSchema: _projectBuildOutput(),
    annotations: _annotations('Build Project Image'),
    callback: (args, extra) => guardToolCall(() async {
      final buildArgs =
          (args['buildArgs'] as Map?)?.map(
            (key, value) => MapEntry(key as String, value as String),
          ) ??
          const <String, String>{};
      final result = await _withCancellation(extra, (cancellation) {
        var lines = 0;
        return service.buildProject(
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

  server.registerTool(
    'project_test',
    title: 'Test Project Image',
    description: '用必传 command 运行一次性测试容器；非零退出是结果数据。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(pattern: _prefixPattern),
        'command': const JsonArray(
          description: '测试命令及参数，必须是非空字符串数组',
          items: JsonString(),
        ),
      },
      required: ['name', 'command'],
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'project': const JsonString(),
        'image': const JsonString(),
        'exitCode': const JsonInteger(),
        'stdout': const JsonString(),
        'stderr': const JsonString(),
        'truncated': const JsonBoolean(),
        'durationMs': const JsonInteger(),
      },
      required: [
        'project',
        'image',
        'exitCode',
        'stdout',
        'stderr',
        'truncated',
        'durationMs',
      ],
    ),
    annotations: _annotations('Test Project Image'),
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(
        extra,
        (cancellation) => service.testProject(
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

  server.registerTool(
    'project_reclaim',
    title: 'Reclaim Project',
    description: '停删项目容器并仅释放无引用项目镜像；dryRun 返回同构预演。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'dryRun': const JsonBoolean(defaultValue: false),
      },
    ),
    outputSchema: _projectReclaimOutput(),
    annotations: _annotations(
      'Reclaim Project',
      destructive: true,
      idempotent: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final result = await service.reclaimProject(
        project: args['project'] as String?,
        path: args['path'] as String?,
        dryRun: args['dryRun'] as bool? ?? false,
      );
      return (
        data: result.toJson(),
        summary:
            '项目 ${result.project} 回收：删除 ${result.deletedContainers.length} 个容器、'
            '${result.deletedImages.length} 个镜像，释放 ${result.disk.reclaimedBytes} 字节',
      );
    }),
  );

  server.registerTool(
    'project_publish',
    title: 'Publish Project Image',
    description: 'tag 并 plain-HTTP 推送到 127.0.0.1:5056，可选删除两个本地 tag。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(pattern: _prefixPattern),
        'deleteLocal': const JsonBoolean(defaultValue: false),
      },
      required: ['name'],
    ),
    outputSchema: _projectPublishOutput(),
    annotations: _annotations('Publish Project Image', idempotent: true),
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(extra, (cancellation) {
        var lines = 0;
        return service.publishProject(
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

  server.registerTool(
    'project_restore',
    title: 'Restore Project Image',
    description: '从本地 plain-HTTP registry 拉回并 tag 回项目镜像名。',
    inputSchema: _selectorInput(
      properties: <String, JsonSchema>{
        'name': const JsonString(pattern: _prefixPattern),
      },
      required: ['name'],
    ),
    outputSchema: _projectRestoreOutput(),
    annotations: _annotations('Restore Project Image', idempotent: true),
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(extra, (cancellation) {
        var lines = 0;
        return service.restoreProject(
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

Map<String, JsonSchema> _selectorProperties() => <String, JsonSchema>{
  'project': const JsonString(
    description: '项目 prefix；与 path 二选一',
    pattern: _prefixPattern,
  ),
  'path': const JsonString(description: '项目目录；与 project 二选一'),
};

JsonObject _selectorInput({
  Map<String, JsonSchema> properties = const <String, JsonSchema>{},
  List<String> required = const <String>[],
}) => JsonObject(
  properties: <String, JsonSchema>{..._selectorProperties(), ...properties},
  required: required,
  additionalProperties: false,
);

ToolAnnotations _annotations(
  String title, {
  bool readOnly = false,
  bool destructive = false,
  bool idempotent = false,
}) => ToolAnnotations(
  title: title,
  readOnlyHint: readOnly,
  destructiveHint: destructive,
  idempotentHint: idempotent,
  openWorldHint: true,
);

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

JsonObject _projectDetailsOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'path': const JsonString(),
    'images': const JsonArray(items: JsonObject()),
    'containers': const JsonArray(items: JsonObject()),
  },
  required: ['project', 'images', 'containers'],
);

JsonObject _projectBuildOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'image': const JsonString(),
    'testsPassed': const JsonBoolean(),
    'exitCode': const JsonInteger(),
    'durationMs': const JsonInteger(),
    'output': const JsonString(),
    'failureLogPath': const JsonString(),
  },
  required: ['project', 'image', 'exitCode', 'durationMs'],
);

JsonObject _projectReclaimOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'containers': const JsonObject(),
    'images': const JsonObject(),
    'disk': const JsonObject(),
    'errors': const JsonArray(items: JsonString()),
  },
  required: ['project', 'containers', 'images', 'disk', 'errors'],
);

JsonObject _projectPublishOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'pushed': const JsonArray(items: JsonObject()),
  },
  required: ['project', 'pushed'],
);

JsonObject _projectRestoreOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'project': const JsonString(),
    'restored': const JsonArray(items: JsonObject()),
  },
  required: ['project', 'restored'],
);
