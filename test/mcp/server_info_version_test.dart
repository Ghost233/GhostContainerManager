import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/app_constants.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// issue #32 验收 1：`serverInfo.version` 必须是真实应用版本，与设置页
/// 「关于」区块同源（lib/services/app_constants.dart 的 [gcmAppVersion]，
/// 构建时由 `--dart-define=GCM_APP_VERSION` 注入），不得再是 '0.0.0'。
void main() {
  GcmMcpServer makeServer({String? appVersion}) {
    final bridge = FakeContainerBridge();
    return GcmMcpServer(
      systemService: SystemService(bridge: bridge, pingInterval: Duration.zero),
      containerService: ContainerService(bridge: bridge),
      port: 0,
      enableJsonResponse: true,
      appVersion: appVersion ?? gcmAppVersion,
    );
  }

  test('serverInfo.version 默认与「关于」区块同源且非 0.0.0', () {
    final server = makeServer();
    expect(server.serverInfo.name, 'ghost-container-manager');
    expect(server.serverInfo.version, gcmAppVersion);
    expect(server.serverInfo.version, isNot('0.0.0'));
  });

  test('注入的固定版本经 initialize 握手透出（e2e）', () async {
    final server = makeServer(appVersion: '9.9.9-issue32');
    await server.start();
    addTearDown(server.stop);
    final http = HttpClient();
    addTearDown(http.close);

    final request = await http.postUrl(
      Uri.parse('http://127.0.0.1:${server.boundPort}/mcp'),
    );
    request.headers
      ..set('content-type', 'application/json')
      ..set('accept', 'application/json, text/event-stream');
    request.write(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{
            'name': 'version-test',
            'version': '0.0.0', // 客户端版本，与被测的 serverInfo 无关
          },
        },
      }),
    );
    final response = await request.close();
    final body = jsonDecode(
      await utf8.decoder.bind(response).join(),
    ) as Map<String, dynamic>;

    final serverInfo =
        (body['result'] as Map<String, dynamic>)['serverInfo']
            as Map<String, dynamic>;
    expect(serverInfo['name'], 'ghost-container-manager');
    expect(serverInfo['version'], '9.9.9-issue32');
    expect(serverInfo['version'], isNot('0.0.0'));
  });
}
