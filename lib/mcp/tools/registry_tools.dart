/// MCP `registry_*` tool handlers (docs/spec/mcp-tools.md §3.7).
///
/// MCP translation for the app-owned local registry. Container and image
/// lifecycle remains in [RegistryService]. Declarative metadata lives in
/// lib/mcp/tool_catalog.dart (ADR-0001).
library;

import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/registry_service.dart';
import 'system_tools.dart';

/// MCP translation for the app-owned local registry. Container and image
/// lifecycle remains in [RegistryService].
void registerRegistryTools(
  ToolRegistrar service,
  RegistryService registryService,
) {
  registerCatalogTool(
    service,
    'registry_status',
    callback: (args, extra) => guardToolCall(() async {
      final result = await registryService.status();
      return (
        data: result.toJson(),
        summary: result.running
            ? 'registry 运行中：127.0.0.1:${result.port}'
            : 'registry 未运行：127.0.0.1:${result.port}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'registry_start',
    callback: (args, extra) => guardToolCall(() async {
      final result = await _withCancellation(extra, (cancellation) {
        var stage = 0;
        return registryService.start(
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

  registerCatalogTool(
    service,
    'registry_stop',
    callback: (args, extra) => guardToolCall(() async {
      final result = await registryService.stop();
      return (
        data: <String, Object?>{'running': result.running},
        summary: result.running ? 'registry 仍在运行' : 'registry 已停止，数据已保留',
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
