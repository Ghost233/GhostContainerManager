import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/mcp/tool_catalog.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Regression + coverage evidence for issue #29 (ADR-0002): gcm_call must
/// validate business arguments against the catalog entry's inputSchema with
/// the mcp_dart built-in validator BEFORE dispatching; failures return
/// INVALID_ARGUMENT and the handler must not run.
///
/// The business handlers here are stubs bound to the real catalog schemas via
/// [registerCatalogTool]; a spy map records which handlers actually executed.
void main() {
  late HttpClient client;
  late StreamableMcpServer httpServer;
  late String baseUrl;
  String? sessionId;
  String? protocolVersion;

  /// Tool names whose stub handler ran (reset per test).
  late Set<String> executed;

  CallToolResult stubResult(String tool) {
    final wire = <String, Object?>{'stub': tool};
    return CallToolResult(
      content: [TextContent(text: jsonEncode(wire))],
      structuredContent: wire,
    );
  }

  setUp(() async {
    sessionId = null;
    protocolVersion = null;
    executed = <String>{};
    httpServer = StreamableMcpServer(
      serverFactory: (_) {
        final server = McpServer(
          const Implementation(name: 'validation-test', version: '1.0.0'),
        );
        final registry = ToolCallbackRegistry();
        for (final tool in <String>[
          'system_status',
          'container_list',
          'container_inspect',
          'container_stop',
          'container_exec',
          'container_create',
        ]) {
          registerCatalogTool(
            registry,
            tool,
            callback: (args, extra) async {
              executed.add(tool);
              return stubResult(tool);
            },
          );
        }
        registerCatalogTools(server, registry);
        return server;
      },
      host: '127.0.0.1',
      port: 0,
      path: '/mcp',
      enableJsonResponse: true,
    );
    await httpServer.start();
    baseUrl = 'http://127.0.0.1:${httpServer.boundPort}/mcp';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await httpServer.stop();
  });

  Future<Map<String, dynamic>> rpc(Map<String, dynamic> body) async {
    final request = await client.postUrl(Uri.parse(baseUrl));
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (sessionId != null) request.headers.set('mcp-session-id', sessionId!);
    if (protocolVersion != null) {
      request.headers.set('mcp-protocol-version', protocolVersion!);
    }
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    expect(response.statusCode, inInclusiveRange(200, 202));
    sessionId ??= response.headers.value('mcp-session-id');
    return text.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> initialize() async {
    final initialized = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{'name': 'test', 'version': '1.0.0'},
      },
    });
    protocolVersion =
        (initialized['result'] as Map<String, dynamic>)['protocolVersion']
            as String?;
    await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
  }

  var nextId = 100;
  Future<Map<String, dynamic>> gcmCall(
    String tool,
    Map<String, dynamic>? arguments,
  ) async {
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': nextId++,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'gcm_call',
        'arguments': <String, dynamic>{'tool': tool, 'arguments': ?arguments},
      },
    });
    return body['result'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> gcmHelp(Map<String, dynamic>? arguments) async {
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': nextId++,
      'method': 'tools/call',
      'params': <String, dynamic>{'name': 'gcm_help', 'arguments': ?arguments},
    });
    return body['result'] as Map<String, dynamic>;
  }

  Map<String, dynamic> expectInvalidArgument(Map<String, dynamic> result) {
    expect(result['isError'], isTrue);
    final structured = (result['structuredContent'] as Map)
        .cast<String, dynamic>();
    final error = (structured['error'] as Map).cast<String, dynamic>();
    expect(error['code'], 'INVALID_ARGUMENT', reason: jsonEncode(structured));
    expect(
      error['message'],
      isA<String>().having((m) => m, 'non-empty', isNotEmpty),
    );
    return error;
  }

  group('已复现问题回归（#28 问题陈述 1）', () {
    test(
      'container_inspect 传 {} → INVALID_ARGUMENT 指明缺 id，handler 未执行',
      () async {
        await initialize();
        final result = await gcmCall('container_inspect', <String, dynamic>{});
        final error = expectInvalidArgument(result);
        expect(error['message'] as String, contains('id'));
        expect(executed, isNot(contains('container_inspect')));
      },
    );

    test(
      'container_list 传 {"all":"invalid-boolean"} → 拒绝，handler 未执行',
      () async {
        await initialize();
        final result = await gcmCall('container_list', <String, dynamic>{
          'all': 'invalid-boolean',
        });
        expectInvalidArgument(result);
        expect(executed, isNot(contains('container_list')));
      },
    );

    test('system_status 传额外字段 → 拒绝，handler 未执行', () async {
      await initialize();
      final result = await gcmCall('system_status', <String, dynamic>{
        'surprise': true,
      });
      expectInvalidArgument(result);
      expect(executed, isNot(contains('system_status')));
    });
  });

  group('schema 校验覆盖（必填/类型/枚举/范围/数组元素/嵌套/额外字段）', () {
    test('枚举：container_list status 非法值被拒绝', () async {
      await initialize();
      final result = await gcmCall('container_list', <String, dynamic>{
        'status': 'bogus',
      });
      expectInvalidArgument(result);
      expect(executed, isNot(contains('container_list')));
    });

    test('数值范围：container_stop timeoutSeconds 低于 minimum 被拒绝', () async {
      await initialize();
      final result = await gcmCall('container_stop', <String, dynamic>{
        'id': 'web',
        'timeoutSeconds': -1,
      });
      expectInvalidArgument(result);
      expect(executed, isNot(contains('container_stop')));
    });

    test('数组元素：container_exec command 含非字符串元素被拒绝', () async {
      await initialize();
      final result = await gcmCall('container_exec', <String, dynamic>{
        'id': 'web',
        'command': <Object?>['ls', 1],
      });
      expectInvalidArgument(result);
      expect(executed, isNot(contains('container_exec')));
    });

    test('嵌套对象：container_create ports 元素缺 container 字段被拒绝', () async {
      await initialize();
      final result = await gcmCall('container_create', <String, dynamic>{
        'image': 'alpine:3.19',
        'ports': <Object?>[
          <String, dynamic>{'host': 8080},
        ],
      });
      expectInvalidArgument(result);
      expect(executed, isNot(contains('container_create')));
    });

    test('额外字段：container_inspect 带未声明字段被拒绝', () async {
      await initialize();
      final result = await gcmCall('container_inspect', <String, dynamic>{
        'id': 'web',
        'verbose': true,
      });
      expectInvalidArgument(result);
      expect(executed, isNot(contains('container_inspect')));
    });
  });

  group('合法调用不受影响', () {
    test('container_inspect 传 id 正常分发到 handler', () async {
      await initialize();
      final result = await gcmCall('container_inspect', <String, dynamic>{
        'id': 'web',
      });
      expect(result['isError'], isNot(true));
      expect((result['structuredContent'] as Map)['stub'], 'container_inspect');
      expect(executed, contains('container_inspect'));
    });

    test('container_list 省略 arguments 正常分发（全部参数可省略）', () async {
      await initialize();
      final result = await gcmCall('container_list', null);
      expect(result['isError'], isNot(true));
      expect(executed, contains('container_list'));
    });

    test('container_stop 带边界内 timeoutSeconds 正常分发', () async {
      await initialize();
      final result = await gcmCall('container_stop', <String, dynamic>{
        'id': 'web',
        'timeoutSeconds': 0,
      });
      expect(result['isError'], isNot(true));
      expect(executed, contains('container_stop'));
    });

    test('未知工具仍返回 NOT_FOUND', () async {
      await initialize();
      final result = await gcmCall('nope_tool', <String, dynamic>{});
      expect(result['isError'], isTrue);
      final structured = (result['structuredContent'] as Map)
          .cast<String, dynamic>();
      expect((structured['error'] as Map)['code'], 'NOT_FOUND');
    });
  });

  group('gcm_help tool 模式参数校验（issue #30）', () {
    test('domain 与 tool 同传 → INVALID_ARGUMENT 互斥错误', () async {
      await initialize();
      final result = await gcmHelp(<String, dynamic>{
        'domain': 'container',
        'tool': 'container_create',
      });
      final error = expectInvalidArgument(result);
      expect(error['message'] as String, contains('互斥'));
    });

    test('未知工具名 → 工具错误并附合法名引导', () async {
      await initialize();
      final result = await gcmHelp(<String, dynamic>{'tool': 'nope_tool'});
      expect(result['isError'], isTrue);
      final structured = (result['structuredContent'] as Map)
          .cast<String, dynamic>();
      final error = (structured['error'] as Map).cast<String, dynamic>();
      expect(error['message'] as String, contains('nope_tool'));
      final hint = error['hint'] as String;
      expect(hint, contains('gcm_help'));
      expect(hint, contains('container_create'));
    });
  });
}
