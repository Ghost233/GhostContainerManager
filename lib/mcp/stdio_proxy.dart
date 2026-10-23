/// stdio thin-proxy helper for the in-app MCP server.
///
/// MCP clients that only speak stdio spawn this helper; it forwards
/// newline-delimited JSON-RPC between stdin/stdout and the app's Streamable
/// HTTP endpoint on 127.0.0.1 (default port 35731). It holds no business
/// logic: session-id propagation, SSE unwrapping, and nothing else.
///
/// Run with: `dart run lib/mcp/stdio_proxy.dart [--port N]`.
/// (A packaged entry point is wired up with the app bundle in a later task.)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  var port = 35731;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.parse(args[i + 1]);
    }
  }
  final proxy = McpStdioProxy(port: port);
  await proxy.run();
}

/// Forwards newline-delimited JSON-RPC (stdin) to the Streamable HTTP MCP
/// endpoint and writes responses back (stdout), one JSON object per line.
class McpStdioProxy {
  McpStdioProxy({required this.port, HttpClient? client})
    : _client = client ?? HttpClient();

  final int port;
  final HttpClient _client;
  String? _sessionId;
  String? _protocolVersion;

  Uri get _endpoint => Uri.parse('http://127.0.0.1:$port/mcp');

  Future<void> run() async {
    final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final response = await forward(line);
      if (response != null) {
        stdout.writeln(response);
      }
    }
  }

  /// Forwards one JSON-RPC message line; returns the response line, or null
  /// for notifications (HTTP 202).
  Future<String?> forward(String line) async {
    final request = await _client.postUrl(_endpoint);
    request.headers
      ..set('content-type', 'application/json')
      ..set('accept', 'application/json, text/event-stream');
    if (_sessionId != null) {
      request.headers.set('mcp-session-id', _sessionId!);
    }
    if (_protocolVersion != null) {
      request.headers.set('mcp-protocol-version', _protocolVersion!);
    }
    request.write(line);
    final response = await request.close();

    final session = response.headers.value('mcp-session-id');
    if (session != null) _sessionId = session;

    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode == 202) return null;
    if (response.statusCode != 200) {
      return jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': null,
        'error': <String, Object?>{
          'code': -32000,
          'message': 'MCP HTTP ${response.statusCode}: $body',
        },
      });
    }

    final contentType = response.headers.contentType?.mimeType ?? '';
    final payload = contentType == 'text/event-stream'
        ? _lastSseData(body)
        : body.trim();
    if (payload == null || payload.isEmpty) return null;

    // Track the negotiated protocol version for subsequent requests.
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['result'] is Map) {
        final negotiated =
            (decoded['result'] as Map)['protocolVersion'] as String?;
        if (negotiated != null) _protocolVersion = negotiated;
      }
    } on FormatException {
      // Forward the payload verbatim; validation is the client's job.
    }
    return payload;
  }

  /// Extracts the JSON payload from the last `data:` line of an SSE body.
  String? _lastSseData(String body) {
    String? last;
    for (final line in const LineSplitter().convert(body)) {
      if (line.startsWith('data:')) {
        last = line.substring(5).trim();
      }
    }
    return last;
  }
}
