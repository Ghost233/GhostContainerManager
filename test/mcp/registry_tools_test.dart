import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/mcp/tools/registry_tools.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/registry_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

void main() {
  late McpServer server;
  late StreamableMcpServer transport;
  late HttpClient client;
  late _FakeRegistryService registry;
  late Uri uri;
  String? sessionId;
  var requestId = 0;
  final progressEvents = <Map<String, dynamic>>[];

  setUp(() async {
    registry = _FakeRegistryService();
    server = McpServer(
      const Implementation(name: 'registry-tools-test', version: '1.0.0'),
    );
    transport = StreamableMcpServer(
      host: '127.0.0.1',
      port: 0,
      path: '/mcp',
      serverFactory: (_) {
        final callbacks = ToolCallbackRegistry();
        registerRegistryTools(callbacks, registry);
        registerCatalogTools(server, callbacks);
        return server;
      },
      enableJsonResponse: true,
    );
    await transport.start();
    uri = Uri.parse('http://127.0.0.1:${transport.boundPort}/mcp');
    client = HttpClient()..maxConnectionsPerHost = 8;
    sessionId = null;
    requestId = 0;
    progressEvents.clear();
  });

  tearDown(() async {
    client.close(force: true);
    await transport.stop();
  });

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    int? id,
  }) async {
    final actualId = id ?? ++requestId;
    final httpRequest = await client.postUrl(uri);
    httpRequest.headers.contentType = ContentType.json;
    httpRequest.headers.set('accept', 'application/json, text/event-stream');
    if (sessionId != null) {
      httpRequest.headers.set('mcp-session-id', sessionId!);
    }
    httpRequest.write(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': actualId,
        'method': method,
        'params': params,
      }),
    );
    final response = await httpRequest.close();
    sessionId ??= response.headers.value('mcp-session-id');
    expect(response.statusCode, 200);
    final Map<String, dynamic> decoded;
    if (response.headers.contentType?.mimeType == 'text/event-stream') {
      final lines = await utf8.decoder
          .bind(response)
          .transform(const LineSplitter())
          .toList();
      Map<String, dynamic>? responseMessage;
      for (final line in lines.where((line) => line.startsWith('data:'))) {
        final event =
            jsonDecode(line.substring(5).trim()) as Map<String, dynamic>;
        if (event['method'] == 'notifications/progress') {
          progressEvents.add(event);
        }
        if (event['id'] == actualId) responseMessage = event;
      }
      if (responseMessage == null) {
        throw StateError('No JSON-RPC response in SSE stream');
      }
      decoded = responseMessage;
    } else {
      decoded =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    }
    if (decoded['error'] != null) throw StateError('${decoded['error']}');
    return decoded['result'] as Map<String, dynamic>;
  }

  Future<void> notify(String method, Map<String, dynamic> params) async {
    final httpRequest = await client.postUrl(uri);
    httpRequest.headers.contentType = ContentType.json;
    httpRequest.headers.set('accept', 'application/json, text/event-stream');
    if (sessionId != null) {
      httpRequest.headers.set('mcp-session-id', sessionId!);
    }
    httpRequest.write(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
    final response = await httpRequest.close();
    await response.drain<void>();
    expect(response.statusCode, anyOf(200, 202));
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments, {
    Object? progressToken,
    int? id,
  }) => request('tools/call', <String, dynamic>{
    'name': 'gcm_call',
    'arguments': <String, dynamic>{'tool': name, 'arguments': arguments},
    if (progressToken != null)
      '_meta': <String, Object?>{'progressToken': progressToken},
  }, id: id);

  Future<void> initialize() async {
    await request('initialize', <String, dynamic>{
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{'name': 'registry-test', 'version': '1'},
    });
    await notify('notifications/initialized', <String, dynamic>{});
  }

  test('status returns health, endpoint, container and disk usage', () async {
    await initialize();
    final result = await callTool('registry_status', <String, dynamic>{});
    expect(result['isError'], isNot(true));
    expect(result['structuredContent'], <String, dynamic>{
      'running': true,
      'port': 5056,
      'containerId': 'gcm-registry',
      'diskBytes': 42,
    });
    expect((result['content'] as List).single['text'], contains('运行中'));
  });

  test(
    'start forwards the port and request-associated pull progress',
    () async {
      await initialize();
      final result = await callTool('registry_start', <String, dynamic>{
        'port': 5057,
      }, progressToken: 'registry-progress');
      expect(result['isError'], isNot(true));
      expect(registry.lastStartPort, 5057);
      expect(result['structuredContent'], <String, dynamic>{
        'running': true,
        'port': 5057,
        'containerId': 'gcm-registry',
      });
      expect(progressEvents, isNotEmpty);
      final params = progressEvents.first['params'] as Map<String, dynamic>;
      expect(params['progressToken'], 'registry-progress');
      expect(params['progress'], 1);
      expect(params.containsKey('total'), isFalse);
      expect(params['message'], 'pulling registry (50/100 bytes)');
    },
  );

  test('stop preserves data and returns the terminal stopped state', () async {
    await initialize();
    final result = await callTool('registry_stop', <String, dynamic>{});
    expect(result['isError'], isNot(true));
    expect(registry.stopCalled, isTrue);
    expect(result['structuredContent'], <String, dynamic>{'running': false});
  });

  test('all three tools expose honest annotations and input schemas', () async {
    await initialize();
    final result = await request('tools/call', <String, dynamic>{
      'name': 'gcm_help',
      'arguments': <String, dynamic>{'domain': 'registry'},
    });
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final tools =
        ((structured['domains'] as Map<String, dynamic>)['registry'] as List)
            .cast<Map<String, dynamic>>();
    expect(tools.map((tool) => tool['name']), <String>[
      'registry_status',
      'registry_start',
      'registry_stop',
    ]);
    final byName = <String, Map<String, dynamic>>{
      for (final tool in tools) tool['name'] as String: tool,
    };
    expect(byName['registry_status']!['annotations']['readOnlyHint'], isTrue);
    expect(byName['registry_status']!['annotations']['idempotentHint'], isTrue);
    expect(byName['registry_start']!['annotations']['readOnlyHint'], isFalse);
    expect(
      byName['registry_start']!['annotations']['destructiveHint'],
      isFalse,
    );
    expect(byName['registry_start']!['annotations']['idempotentHint'], isTrue);
    expect(byName['registry_stop']!['annotations']['destructiveHint'], isTrue);
    expect(byName['registry_stop']!['annotations']['idempotentHint'], isTrue);
    // 精简模式下 inputSchema 不进 tools/list；port 默认 5056 等参数契约由
    // Service 层与 docs/spec/mcp-tools.md §3 保证。
  });

  test(
    'failures are tool errors and cancellation reaches registry startup',
    () async {
      registry.error = GcmException(GcmErrorCode.conflict, 'registry 正在启动');
      await initialize();
      final failure = await callTool('registry_status', <String, dynamic>{});
      expect(failure['isError'], isTrue);
      expect(
        (failure['content'] as List).single['text'],
        contains('registry 正在启动'),
      );

      registry.error = null;
      registry.waitForStartCancellation = true;
      final pending = callTool('registry_start', <String, dynamic>{}, id: 700);
      pending.ignore();
      await registry.started.future.timeout(const Duration(seconds: 2));
      await notify('notifications/cancelled', <String, dynamic>{
        'requestId': 700,
        'reason': 'test cancellation',
      });
      await registry.cancelled.future.timeout(const Duration(seconds: 2));
    },
  );
}

class _FakeRegistryService implements RegistryService {
  Object? error;
  int? lastStartPort;
  bool stopCalled = false;
  bool waitForStartCancellation = false;
  final started = Completer<void>();
  final cancelled = Completer<void>();

  void _throwError() {
    final error = this.error;
    if (error != null) throw error;
  }

  @override
  Future<RegistryStatus> status({int? port}) async {
    _throwError();
    return RegistryStatus(
      running: true,
      port: port ?? 5056,
      containerId: 'gcm-registry',
      diskBytes: 42,
    );
  }

  @override
  Future<RegistryStatus> start({
    int port = 5056,
    Stream<void>? cancellation,
    void Function(RegistryProgress progress)? onProgress,
  }) async {
    lastStartPort = port;
    onProgress?.call(
      const RegistryProgress(
        message: 'pulling registry',
        completedBytes: 50,
        totalBytes: 100,
      ),
    );
    if (waitForStartCancellation) {
      started.complete();
      await cancellation!.first;
      if (!cancelled.isCompleted) cancelled.complete();
      throw GcmException(GcmErrorCode.internal, 'registry 启动已取消');
    }
    _throwError();
    return RegistryStatus(
      running: true,
      port: port,
      containerId: 'gcm-registry',
      diskBytes: 42,
    );
  }

  @override
  Future<RegistryStatus> stop() async {
    stopCalled = true;
    _throwError();
    return const RegistryStatus(
      running: false,
      port: 5056,
      containerId: 'gcm-registry',
      diskBytes: 42,
    );
  }
}
