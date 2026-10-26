import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

import '../services/container_service_test.dart' show snapshotPayload;

/// End-to-end evidence for issue #17 acceptance 4: an MCP client speaking
/// Streamable HTTP calls container_list / container_inspect / container_stats
/// and gets structuredContent plus a text summary; label filtering and the
/// two-layer error model are exercised against the fake bridge.
void main() {
  late FakeContainerBridge bridge;
  late GcmMcpServer server;
  final http = HttpClient();

  String? sessionId;
  String? protocolVersion;

  Uri endpoint() => Uri.parse('http://127.0.0.1:${server.boundPort}/mcp');

  setUp(() async {
    sessionId = null;
    protocolVersion = null;
    bridge = FakeContainerBridge()
      ..containers = [
        snapshotPayload(
          id: 'web',
          labels: const {'com.ghost233.compose.project': 'shop'},
        ),
        snapshotPayload(
          id: 'db',
          status: 'stopped',
          startedAt: null,
          labels: const {'com.ghost233.compose.project': 'shop'},
        ),
        snapshotPayload(
          id: 'other',
          labels: const {'com.ghost233.compose.project': 'blog'},
        ),
      ];
    server = GcmMcpServer(
      systemService: SystemService(bridge: bridge, pingInterval: Duration.zero),
      containerService: ContainerService(bridge: bridge),
      port: 0,
      enableJsonResponse: true,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> rpc(Map<String, dynamic> message) async {
    final request = await http.postUrl(endpoint());
    request.headers
      ..set('content-type', 'application/json')
      ..set('accept', 'application/json, text/event-stream');
    if (sessionId != null) request.headers.set('mcp-session-id', sessionId!);
    if (protocolVersion != null) {
      request.headers.set('mcp-protocol-version', protocolVersion!);
    }
    request.write(jsonEncode(message));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    expect(response.statusCode, inInclusiveRange(200, 202));
    sessionId ??= response.headers.value('mcp-session-id');
    return body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> initialize() async {
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{
          'name': 'container-e2e',
          'version': '0',
        },
      },
    });
    protocolVersion =
        (body['result'] as Map<String, dynamic>)['protocolVersion'] as String?;
    await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 99,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'gcm_call',
        'arguments': <String, dynamic>{'tool': name, 'arguments': arguments},
      },
    });
    return body['result'] as Map<String, dynamic>;
  }

  test('tools/list 只暴露精简入口，容器工具经 gcm_help 目录可见', () async {
    await initialize();
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = (body['result'] as Map<String, dynamic>)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name']).toSet();
    // 精简注册模式：tools/list 只有 gcm_help/gcm_call 两个入口。
    expect(names, <String>{'gcm_help', 'gcm_call'});

    final helpBody = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'gcm_help',
        'arguments': <String, dynamic>{'domain': 'container'},
      },
    });
    final structured =
        (helpBody['result'] as Map<String, dynamic>)['structuredContent']
            as Map<String, dynamic>;
    final catalog =
        (structured['domains'] as Map<String, dynamic>)['container'] as List;
    final byName = <String, Map<String, dynamic>>{
      for (final tool in catalog)
        (tool as Map)['name'] as String: tool.cast<String, dynamic>(),
    };

    const readTitles = <String, String>{
      'container_list': 'List Containers',
      'container_inspect': 'Inspect Container',
      'container_stats': 'Container Stats',
    };
    for (final entry in readTitles.entries) {
      final tool = byName[entry.key]!;
      expect(tool['title'], entry.value);
      expect(
        (tool['annotations'] as Map<String, dynamic>)['readOnlyHint'],
        isTrue,
        reason: entry.key,
      );
    }
    expect(byName, isNot(contains('container_logs'))); // #13: UI 专属

    const writeTitles = <String, String>{
      'container_create': 'Create Container',
      'container_start': 'Start Container',
      'container_stop': 'Stop Container',
      'container_restart': 'Restart Container',
      'container_kill': 'Kill Container',
      'container_delete': 'Delete Container',
      'container_exec': 'Execute Container Command',
    };
    for (final entry in writeTitles.entries) {
      final tool = byName[entry.key]!;
      expect(tool['title'], entry.value);
      final annotations = tool['annotations'] as Map<String, dynamic>;
      expect(annotations['readOnlyHint'], isFalse, reason: entry.key);
      expect(
        annotations['destructiveHint'],
        entry.key == 'container_kill' || entry.key == 'container_delete',
        reason: entry.key,
      );
      expect(
        annotations['idempotentHint'],
        entry.key != 'container_create' &&
            entry.key != 'container_exec' &&
            // issue #32：restart 非幂等（每次都是完整 stop+start 周期）。
            entry.key != 'container_restart',
        reason: entry.key,
      );
    }
  });

  test('container_list 返回 structuredContent + 文本摘要', () async {
    await initialize();
    final result = await callTool('container_list', <String, dynamic>{});

    expect(result['isError'], isNot(true));
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final containers = structured['containers'] as List;
    expect(containers, hasLength(3));
    final web = containers.firstWhere((c) => (c as Map)['id'] == 'web') as Map;
    expect(web['name'], 'web');
    expect(web['status'], 'running');
    expect((web['networks'] as List).single['ip'], '192.168.64.3');
    final content = result['content'] as List;
    expect((content.first as Map)['text'], contains('共 3 个容器'));
  });

  test('container_list label 精确过滤', () async {
    await initialize();
    final result = await callTool('container_list', <String, dynamic>{
      'label': 'com.ghost233.compose.project=shop',
    });
    final containers =
        (result['structuredContent'] as Map<String, dynamic>)['containers']
            as List;
    expect(containers.map((c) => (c as Map)['id']), containsAll(['web', 'db']));
    expect(containers, hasLength(2));
  });

  test('container_list all=false 只返回运行中', () async {
    await initialize();
    final result = await callTool('container_list', <String, dynamic>{
      'all': false,
    });
    final containers =
        (result['structuredContent'] as Map<String, dynamic>)['containers']
            as List;
    // issue #31：列表按 id 升序输出，分页细节见 list_pagination_test。
    expect(containers.map((c) => (c as Map)['id']), ['other', 'web']);
  });

  test('container_inspect 返回完整 configuration', () async {
    await initialize();
    final result = await callTool('container_inspect', <String, dynamic>{
      'id': 'web',
    });
    final container =
        (result['structuredContent'] as Map<String, dynamic>)['container']
            as Map<String, dynamic>;
    expect(container['stopSignal'], 'SIGTERM');
    expect(container['environment'], ['A=1', 'B=2']);
    expect((container['configuration'] as Map)['id'], 'web');
  });

  test('container_inspect 未知 id → isError + NOT_FOUND', () async {
    await initialize();
    final result = await callTool('container_inspect', <String, dynamic>{
      'id': 'ghost',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'NOT_FOUND');
    expect((structured['error'] as Map)['hint'], isNotNull);
  });

  test('container_stats 返回快照结构', () async {
    await initialize();
    final result = await callTool('container_stats', <String, dynamic>{
      'id': 'web',
    });
    expect(result['isError'], isNot(true));
    final stats =
        (result['structuredContent'] as Map<String, dynamic>)['stats']
            as Map<String, dynamic>;
    expect(stats['id'], 'web');
    expect(stats['memoryUsageBytes'], 64 * 1024 * 1024);
    expect(stats['memoryUtilization'], closeTo(0.125, 0.001));
    expect(stats['numProcesses'], 3);
  });

  test('container_stats 停止容器 → isError + CONFLICT', () async {
    bridge.statsFailures['db'] = 'container is not running';
    await initialize();
    final result = await callTool('container_stats', <String, dynamic>{
      'id': 'db',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'CONFLICT');
  });

  test('container_exec 返回退出码、分管输出与截断标记', () async {
    bridge.execResult = const BridgeExecResult(
      exitCode: 23,
      stdout: 'partial stdout',
      stderr: 'stderr text',
      stdoutTruncated: true,
    );
    await initialize();

    final result = await callTool('container_exec', <String, dynamic>{
      'id': 'web',
      'command': <String>['sh', '-c', 'exit 23'],
      'env': <String, String>{'MODE': 'production'},
      'workdir': '/srv',
      'timeoutSeconds': 9,
    });

    expect(result['isError'], isNot(true));
    expect(result['structuredContent'], <String, Object?>{
      'exitCode': 23,
      'stdout': 'partial stdout',
      'stderr': 'stderr text',
      'truncated': true,
    });
    expect(bridge.execRequests.single, <String, Object?>{
      'id': 'web',
      'command': <String>['sh', '-c', 'exit 23'],
      'env': <String>['MODE=production'],
      'workdir': '/srv',
      'user': null,
      'timeoutSeconds': 9,
    });
    final content = result['content'] as List;
    expect((content.first as Map)['text'], contains('退出码 23'));
    expect((content.first as Map)['text'], contains('截断'));
  });

  test('container_exec 非运行容器走统一 CONFLICT guard', () async {
    await initialize();
    final result = await callTool('container_exec', <String, dynamic>{
      'id': 'db',
      'command': <String>['true'],
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'CONFLICT');
  });

  test('container_exec 超时：TIMEOUT 含资源标识与查询方法（issue #32）', () async {
    // 超时 = 放弃等待，进程可能仍在容器内运行（状态未知语义，见
    // test/mcp/long_task_semantics_test.dart 的核对结论）；错误必须给出
    // 容器 id 与查询途径，不得让 agent 误以为进程已停止。
    bridge.execResult = const BridgeExecResult(
      exitCode: -1,
      stdout: '',
      stderr: '',
      timedOut: true,
    );
    await initialize();
    final result = await callTool('container_exec', <String, dynamic>{
      'id': 'web',
      'command': <String>['sleep', '600'],
      'timeoutSeconds': 5,
    });
    expect(result['isError'], isTrue);
    final error =
        (result['structuredContent'] as Map<String, dynamic>)['error'] as Map;
    expect(error['code'], 'TIMEOUT');
    expect(error['message'], contains('web'));
    expect(error['hint'], contains('container_inspect'));
  });

  test('container_create 转换 MCP 参数并可创建后启动', () async {
    await initialize();
    final result = await callTool('container_create', <String, dynamic>{
      'name': 'api',
      'image': 'nginx:latest',
      'command': <String>['nginx', '-g', 'daemon off;'],
      'env': <String, String>{'MODE': 'production'},
      'ports': <Map<String, Object>>[
        <String, Object>{'host': 8080, 'container': 80},
      ],
      'network': 'default',
      'mounts': <Map<String, Object>>[
        <String, Object>{
          'source': '/tmp/api-data',
          'target': '/var/lib/api',
          'readonly': true,
        },
      ],
      'labels': <String, String>{'app': 'api', 'tier': 'backend'},
      'start': true,
    });

    expect(result['isError'], isNot(true));
    expect(bridge.createRequests.single, <String, Object?>{
      'id': 'api',
      'image': 'nginx:latest',
      'command': <String>['nginx', '-g', 'daemon off;'],
      'env': <String>['MODE=production'],
      'ports': <String>['8080:80/tcp'],
      'network': 'default',
      'mounts': <Map<String, Object?>>[
        <String, Object?>{
          'source': '/tmp/api-data',
          'target': '/var/lib/api',
          'readonly': true,
        },
      ],
      'labels': <String, String>{'app': 'api', 'tier': 'backend'},
    });
    expect(bridge.startCalls, 1);
    expect(result['structuredContent'], <String, Object?>{
      'id': 'api',
      'name': 'api',
      'status': 'running',
      'warnings': <Object?>[],
    });
  });

  test('六个写工具经过 Service 并返回权威 structuredContent', () async {
    await initialize();

    bridge.stoppedGracefully = false;
    final stopped = await callTool('container_stop', <String, dynamic>{
      'id': 'web',
      'timeoutSeconds': 7,
    });
    expect(stopped['structuredContent'], <String, Object?>{
      'id': 'web',
      'status': 'stopped',
      'stoppedGracefully': false,
    });
    expect(bridge.calls, contains('containerStop:web timeout=7'));

    final started = await callTool('container_start', <String, dynamic>{
      'id': 'web',
    });
    expect(started['structuredContent'], <String, Object?>{
      'id': 'web',
      'status': 'running',
    });

    final restarted = await callTool('container_restart', <String, dynamic>{
      'id': 'web',
    });
    expect(restarted['structuredContent'], <String, Object?>{
      'id': 'web',
      'status': 'running',
    });
    expect(bridge.calls, contains('containerStop:web timeout=5'));

    final killed = await callTool('container_kill', <String, dynamic>{
      'id': 'web',
    });
    expect(killed['structuredContent'], <String, Object?>{
      'id': 'web',
      'signal': 'KILL',
      'status': 'stopped',
    });

    final deleted = await callTool('container_delete', <String, dynamic>{
      'id': 'web',
      'force': true,
    });
    expect(deleted['structuredContent'], <String, Object?>{
      'id': 'web',
      'deleted': true,
    });
    expect(bridge.deleteCalls, 1);
  });

  test(
    'create start failure preserves id and created details over MCP',
    () async {
      bridge.writeFailures['start:api'] = 'bootstrap failed';
      await initialize();

      final result = await callTool('container_create', <String, dynamic>{
        'name': 'api',
        'image': 'nginx:latest',
        'start': true,
      });

      expect(result['isError'], isTrue);
      final error =
          (result['structuredContent'] as Map<String, dynamic>)['error'] as Map;
      expect(error['details'], <String, Object?>{'id': 'api', 'created': true});
    },
  );

  test('create missing local image returns actionable NOT_FOUND', () async {
    bridge.writeFailures['create:api'] =
        'image with reference missing:latest not found';
    await initialize();

    final result = await callTool('container_create', <String, dynamic>{
      'name': 'api',
      'image': 'missing:latest',
    });

    expect(result['isError'], isTrue);
    final error =
        (result['structuredContent'] as Map<String, dynamic>)['error'] as Map;
    expect(error['code'], 'NOT_FOUND');
    expect(error['message'], contains('missing:latest'));
    expect(error['hint'], '先在镜像页拉取或调用 image_pull');
  });

  test('写工具业务错误沿用统一 guard 和 CONFLICT', () async {
    await initialize();
    final result = await callTool('container_delete', <String, dynamic>{
      'id': 'web',
    });
    expect(result['isError'], isTrue);
    expect(
      (result['structuredContent'] as Map)['error'],
      isA<Map>().having((e) => e['code'], 'code', 'CONFLICT'),
    );
    final content = result['content'] as List;
    expect((content.single as Map)['text'], contains('"code":"CONFLICT"'));
    expect(bridge.deleteCalls, 0);
  });
}
