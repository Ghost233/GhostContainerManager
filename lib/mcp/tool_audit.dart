/// Bounded audit trail for MCP tool calls (issue #16, "最近调用简表").
///
/// Records only operational metadata — tool name, start time, success flag and
/// duration. Arguments and results are deliberately not recorded so tokens,
/// paths or command text never leak into the settings UI.
library;

import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

import 'tool_registrar.dart';

/// One completed MCP tool call.
class McpCallRecord {
  const McpCallRecord({
    required this.tool,
    required this.startedAt,
    required this.succeeded,
    required this.duration,
  });

  final String tool;
  final DateTime startedAt;
  final bool succeeded;
  final Duration duration;

  @override
  String toString() =>
      'McpCallRecord($tool, succeeded=$succeeded, ${duration.inMilliseconds}ms)';
}

/// Thread-safe-in-single-isolate ring buffer of the most recent calls.
///
/// Newest record is first. [capacity] keeps the settings page bounded and the
/// memory footprint predictable.
class McpToolAuditor {
  McpToolAuditor({this.capacity = 20, DateTime Function()? clock})
    : assert(capacity > 0),
      _clock = clock ?? DateTime.now;

  final int capacity;
  final DateTime Function() _clock;
  final List<McpCallRecord> _records = [];
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );

  /// Most recent calls, newest first. Unmodifiable snapshot.
  List<McpCallRecord> get records => List<McpCallRecord>.unmodifiable(_records);

  /// Emits after each completed call so presentation layers can refresh.
  Stream<void> get changes => _changes.stream;

  /// Records a finished call. Called by [AuditedMcpServer] in a `finally` so
  /// thrown callbacks still appear as failures.
  void record({
    required String tool,
    required DateTime startedAt,
    required bool succeeded,
    required Duration duration,
  }) {
    _records.insert(
      0,
      McpCallRecord(
        tool: tool,
        startedAt: startedAt,
        succeeded: succeeded,
        duration: duration,
      ),
    );
    if (_records.length > capacity) {
      _records.removeRange(capacity, _records.length);
    }
    _changes.add(null);
  }

  /// Convenience used by the server wrapper; takes the start instant.
  void recordCall({
    required String tool,
    required bool succeeded,
    required Duration duration,
    DateTime? startedAt,
  }) {
    record(
      tool: tool,
      startedAt: startedAt ?? _clock(),
      succeeded: succeeded,
      duration: duration,
    );
  }

  Future<void> dispose() => _changes.close();
}

/// [McpServer] that records every tool invocation into [auditor].
///
/// Tool registration is routed through this class by [GcmMcpServer.buildServer],
/// so all domains are audited without each tool file knowing about the audit
/// layer. Arguments and results are not captured (privacy/boundedness).
class AuditedMcpServer extends McpServer implements ToolRegistrar {
  AuditedMcpServer(
    super.serverInfo, {
    super.options,
    required this.auditor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final McpToolAuditor auditor;
  final DateTime Function() _clock;

  @override
  RegisteredTool registerTool(
    String name, {
    String? title,
    String? description,
    ToolInputSchema? inputSchema,
    ToolOutputSchema? outputSchema,
    ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required ToolFunction callback,
  }) {
    Future<CallToolResult> wrapped(
      Map<String, dynamic> args,
      RequestHandlerExtra extra,
    ) async {
      final startedAt = _clock();
      final stopwatch = Stopwatch()..start();
      var succeeded = false;
      try {
        final result = await callback(args, extra);
        succeeded = !result.isError;
        return result;
      } finally {
        stopwatch.stop();
        auditor.record(
          tool: name,
          startedAt: startedAt,
          succeeded: succeeded,
          duration: stopwatch.elapsed,
        );
      }
    }

    return super.registerTool(
      name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations,
      meta: meta,
      callback: wrapped,
    );
  }
}
