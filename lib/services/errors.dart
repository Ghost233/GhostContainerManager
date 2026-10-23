/// Error model shared by the Service layer and the MCP error mapping.
///
/// Wire names match docs/spec/mcp-tools.md §5 (two-layer model: protocol
/// errors stay in JSON-RPC; tool execution errors surface as
/// `{error: {code, message, hint?}}`).
library;

enum GcmErrorCode {
  runtimeUnavailable('RUNTIME_UNAVAILABLE'),
  versionMismatch('VERSION_MISMATCH'),
  notFound('NOT_FOUND'),
  conflict('CONFLICT'),
  ambiguousId('AMBIGUOUS_ID'),
  permissionDenied('PERMISSION_DENIED'),
  invalidArgument('INVALID_ARGUMENT'),
  timeout('TIMEOUT'),
  internal('INTERNAL');

  const GcmErrorCode(this.wireName);

  /// Stable wire name used in MCP/UI error payloads.
  final String wireName;
}

/// Structured service-layer failure. UI and MCP adaptors render it; the
/// Service layer never returns ad-hoc strings for expected failures.
class GcmException implements Exception {
  const GcmException(this.code, this.message, {this.hint, this.cause});

  final GcmErrorCode code;
  final String message;

  /// Actionable next step for the caller (docs link, retry advice, …).
  final String? hint;

  /// Original error / raw output kept for diagnostics.
  final Object? cause;

  /// JSON-serialisable MCP tool-error payload (`isError: true` content).
  Map<String, Object?> toWire() => <String, Object?>{
    'error': <String, Object?>{
      'code': code.wireName,
      'message': message,
      if (hint != null) 'hint': hint,
    },
  };

  @override
  String toString() =>
      'GcmException(${code.wireName}: $message${hint != null ? ' hint=$hint' : ''})';
}
