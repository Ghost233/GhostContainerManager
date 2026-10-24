import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/registry_service.dart';
import 'system_tools.dart';

/// MCP translation for the app-owned local registry. Container and image
/// lifecycle remains in [RegistryService].
void registerRegistryTools(McpServer server, RegistryService service) {
  server.registerTool(
    'registry_status',
    title: 'Get Registry Status',
    description: '读取本地 registry 容器、HTTP 健康、端口与数据目录占用。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: _registryStatusOutput(),
    annotations: _annotations('Get Registry Status', readOnly: true),
    callback: (args, extra) => guardToolCall(() async {
      final result = await service.status();
      return (
        data: result.toJson(),
        summary: result.running
            ? 'registry 运行中：127.0.0.1:${result.port}'
            : 'registry 未运行：127.0.0.1:${result.port}',
      );
    }),
  );

  server.registerTool(
    'registry_start',
    title: 'Start Local Registry',
    description: '幂等启动 127.0.0.1 上的 registry；首次会拉取并创建容器，保留已有数据。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{'port': _portSchema()},
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'running': const JsonBoolean(),
        'port': const JsonInteger(),
        'containerId': const JsonString(),
      },
      required: ['running', 'port', 'containerId'],
    ),
    annotations: _annotations('Start Local Registry'),
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(extra, (cancellation) {
        var stage = 0;
        return service.start(
          port: args['port'] as int? ?? 5056,
          cancellation: cancellation,
          onProgress: (progress) {
            stage += 1;
            final total = progress.totalBytes;
            final message = total == null
                ? progress.message
                : '${progress.message} (${progress.completedBytes}/$total bytes)';
            _sendProgress(extra, stage.toDouble(), message: message);
          },
        );
      });
      return (
        data: <String, Object?>{
          'running': result.running,
          'port': result.port,
          'containerId': result.containerId,
        },
        summary: 'registry 已就绪：http://127.0.0.1:${result.port}/v2/',
      );
    }),
  );

  server.registerTool(
    'registry_stop',
    title: 'Stop Local Registry',
    description: '停止 registry 容器，不删除容器或其持久化数据。',
    inputSchema: JsonObject(additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'running': const JsonBoolean()},
      required: ['running'],
    ),
    annotations: _annotations('Stop Local Registry', destructive: true),
    callback: (args, extra) => guardToolCall(() async {
      final result = await service.stop();
      return (
        data: <String, Object?>{'running': result.running},
        summary: result.running ? 'registry 仍在运行' : 'registry 已停止，数据已保留',
      );
    }),
  );
}

JsonInteger _portSchema() => const JsonInteger(
  description: '宿主机 loopback 端口',
  defaultValue: 5056,
  minimum: 1,
  maximum: 65535,
);

JsonObject _registryStatusOutput() => JsonObject(
  properties: <String, JsonSchema>{
    'running': const JsonBoolean(),
    'port': const JsonInteger(),
    'containerId': const JsonString(),
    'diskBytes': const JsonInteger(),
  },
  required: ['running', 'port'],
);

ToolAnnotations _annotations(
  String title, {
  bool readOnly = false,
  bool destructive = false,
}) => ToolAnnotations(
  title: title,
  readOnlyHint: readOnly,
  destructiveHint: destructive,
  idempotentHint: true,
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
    // A short operation may never listen; close() would wait for that listener.
    unawaited(cancellation.close());
  }
}

void _sendProgress(
  RequestHandlerExtra extra,
  double progress, {
  required String message,
}) {
  if (extra.meta?['progressToken'] == null) return;
  try {
    unawaited(
      extra.sendProgress(progress, message: message).catchError((Object _) {}),
    );
  } on StateError {
    // The client can disconnect while the registry is still finishing work.
  }
}
