/// Real-environment MCP acceptance client (issue #33 / milestone #28 T5).
///
/// Talks to a running Ghost Container Manager app's in-app MCP server over
/// both transports:
///   - Streamable HTTP: direct POST to `http://127.0.0.1:PORT/mcp`
///   - stdio: spawns `DART lib/mcp/stdio_proxy.dart --port PORT` and
///     speaks newline-delimited JSON-RPC over its stdin/stdout.
///
/// Subcommands:
///   smoke        initialize handshake on both channels; asserts
///                serverInfo.version != "0.0.0" and non-empty, protocolVersion
///                present, tools/list == {gcm_help, gcm_call} exactly.
///   chain        gcm_call system_status -> project_list -> image_list on both
///                channels; prints real-data summaries.
///   concurrency  5 concurrent system_status calls per channel; asserts all
///                five results are identical.
///   pagination   walks image_list/container_list with a small limit; asserts
///                the walk is complete, stably ordered, non-overlapping and
///                totals match; cross-checks totals against `container` CLI.
///   help-modes   exercises gcm_help default / domain / tool modes and prints
///                the outcome of each (evidence for docs).
///
/// Every subcommand prints structured `ACCEPT CHANNEL CHECK PASS|FAIL`
/// detail lines plus a final `RESULT SUBCOMMAND PASS|FAIL` line and
/// exits 0 on success, 1 on failure.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kProtocolVersion = '2025-06-18';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: mcp_acceptance.dart <smoke|chain|concurrency|pagination|'
      'help-modes> [--port N] [--repo PATH] [--dart-exe PATH]',
    );
    exit(2);
  }
  final command = args[0];
  var port = 35731;
  var repo = Directory.current.path;
  var dartExe = Platform.resolvedExecutable;
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) port = int.parse(args[++i]);
    if (args[i] == '--repo' && i + 1 < args.length) repo = args[++i];
    if (args[i] == '--dart-exe' && i + 1 < args.length) dartExe = args[++i];
  }

  final http = HttpChannel(port);
  final stdio = StdioChannel(port: port, repo: repo, dartExe: dartExe);
  var failures = 0;
  void check(String channel, String name, bool ok, String detail) {
    if (!ok) failures++;
    stdout.writeln('ACCEPT $channel $name ${ok ? 'PASS' : 'FAIL'} $detail');
  }

  try {
    switch (command) {
      case 'smoke':
        await _smoke(http, 'http', check);
        await _smoke(stdio, 'stdio', check);
      case 'chain':
        await _chain(http, 'http', check);
        await _chain(stdio, 'stdio', check);
      case 'concurrency':
        await _concurrency(http, 'http', check);
        await _concurrency(stdio, 'stdio', check);
      case 'pagination':
        await _pagination(http, 'http', check);
      case 'help-modes':
        await _helpModes(http, 'http', check);
      default:
        stderr.writeln('unknown subcommand: $command');
        exit(2);
    }
  } finally {
    await stdio.close();
    http.close();
  }
  stdout.writeln(
    'RESULT $command ${failures == 0 ? 'PASS' : 'FAIL'} failures=$failures',
  );
  exit(failures == 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Channels
// ---------------------------------------------------------------------------

class _Session {
  String? sessionId;
  String? protocolVersion;
  int nextId = 1;
}

/// One MCP channel: sends JSON-RPC requests, returns decoded result maps.
abstract class Channel {
  final session = _Session();

  /// Sends one request/notification; returns the decoded response body, or
  /// null for notifications. Throws on transport-level failure.
  Future<Map<String, dynamic>?> sendRaw(Map<String, dynamic> message);

  Future<Map<String, dynamic>> request(String method, [Object? params]) async {
    final id = session.nextId++;
    final body = await sendRaw(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    });
    if (body == null) {
      throw StateError('$method: expected a response, got none');
    }
    if (body['error'] != null) {
      throw StateError('$method failed: ${jsonEncode(body['error'])}');
    }
    return (body['result'] as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> initialize() async {
    final result = await request('initialize', <String, dynamic>{
      'protocolVersion': kProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{
        'name': 'gcm-t5-acceptance',
        'version': '1.0.0',
      },
    });
    session.protocolVersion = result['protocolVersion'] as String?;
    await sendRaw(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    return result;
  }

  Future<Map<String, dynamic>> callTool(
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final result = await request('tools/call', <String, dynamic>{
      'name': 'gcm_call',
      'arguments': <String, dynamic>{'tool': tool, 'arguments': arguments},
    });
    return result;
  }

  /// structuredContent of a gcm_call result (throws when isError).
  Future<Map<String, dynamic>> callStructured(
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final result = await callTool(tool, arguments);
    if (result['isError'] == true) {
      throw StateError(
        '$tool returned isError: '
        '${jsonEncode(result['structuredContent'] ?? result['content'])}',
      );
    }
    return (result['structuredContent'] as Map).cast<String, dynamic>();
  }
}

class HttpChannel extends Channel {
  HttpChannel(this.port);
  final int port;
  final HttpClient _client = HttpClient();

  Uri get _endpoint => Uri.parse('http://127.0.0.1:$port/mcp');

  @override
  Future<Map<String, dynamic>?> sendRaw(Map<String, dynamic> message) async {
    final request = await _client.postUrl(_endpoint);
    request.headers
      ..set('content-type', 'application/json')
      ..set('accept', 'application/json, text/event-stream');
    final sessionId = session.sessionId;
    if (sessionId != null) request.headers.set('mcp-session-id', sessionId);
    final protocolVersion = session.protocolVersion;
    if (protocolVersion != null) {
      request.headers.set('mcp-protocol-version', protocolVersion);
    }
    request.write(jsonEncode(message));
    final response = await request.close();
    final sessionHeader = response.headers.value('mcp-session-id');
    if (sessionHeader != null) session.sessionId = sessionHeader;
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode == 202) return null;
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}: $body');
    }
    final mime = response.headers.contentType?.mimeType ?? '';
    final payload = mime == 'text/event-stream'
        ? const LineSplitter()
              .convert(body)
              .lastWhere((l) => l.startsWith('data:'))
              .substring(5)
              .trim()
        : body.trim();
    if (payload.isEmpty) return null;
    return (jsonDecode(payload) as Map).cast<String, dynamic>();
  }

  void close() => _client.close();
}

class StdioChannel extends Channel {
  StdioChannel({required this.port, required this.repo, required this.dartExe});

  final int port;
  final String repo;
  final String dartExe;

  Process? _process;
  final _rawPending = <int, Completer<Map<String, dynamic>?>>{};
  StreamSubscription<String>? _lines;

  /// Serializes stdin writes: a Process stdin sink rejects concurrent writes
  /// ("StreamSink is bound to a stream"), so concurrent callers queue up.
  Future<void> _writeChain = Future<void>.value();

  Future<void> _ensureStarted() async {
    if (_process != null) return;
    final process = await Process.start(
      dartExe,
      <String>['lib/mcp/stdio_proxy.dart', '--port', '$port'],
      workingDirectory: repo,
    );
    _process = process;
    _lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          final decoded = jsonDecode(line) as Map<String, dynamic>;
          final id = decoded['id'];
          final completer = id is int ? _rawPending.remove(id) : null;
          completer?.complete(decoded);
        });
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((code) {
        for (final completer in _rawPending.values) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('stdio proxy exited ($code)'));
          }
        }
      }),
    );
  }

  @override
  Future<Map<String, dynamic>?> sendRaw(Map<String, dynamic> message) async {
    await _ensureStarted();
    final id = message['id'];
    Completer<Map<String, dynamic>?>? completer;
    if (id is int) {
      completer = Completer<Map<String, dynamic>?>();
      _rawPending[id] = completer;
    }
    final process = _process!;
    _writeChain = _writeChain.then((_) async {
      process.stdin.writeln(jsonEncode(message));
      await process.stdin.flush();
    });
    await _writeChain;
    if (completer == null) return null; // notification
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('stdio response timeout'),
    );
  }

  Future<void> close() async {
    final process = _process;
    _process = null;
    await _lines?.cancel();
    if (process != null) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

typedef Check = void Function(String channel, String name, bool ok, String d);

Future<void> _smoke(Channel channel, String label, Check check) async {
  final init = await channel.initialize();
  final serverInfo = (init['serverInfo'] as Map).cast<String, dynamic>();
  final version = serverInfo['version'] as String? ?? '';
  check(
    label,
    'serverInfo.version',
    version.isNotEmpty && version != '0.0.0',
    'version=$version name=${serverInfo['name']}',
  );
  final protocol = init['protocolVersion'] as String?;
  check(
    label,
    'protocolVersion',
    protocol != null && protocol.isNotEmpty,
    'protocolVersion=$protocol',
  );
  final instructions = init['instructions'] as String?;
  check(
    label,
    'instructions',
    instructions != null && instructions.isNotEmpty,
    'instructions=${instructions?.length ?? 0} chars',
  );
  final list = await channel.request('tools/list');
  final tools = (list['tools'] as List)
      .map((t) => (t as Map)['name'] as String)
      .toSet();
  final sorted = tools.toList()..sort();
  check(
    label,
    'tools/list',
    tools.length == 2 && tools.containsAll(<String>{'gcm_help', 'gcm_call'}),
    'tools=$sorted',
  );
}

Future<void> _chain(Channel channel, String label, Check check) async {
  await channel.initialize();

  final status = await channel.callStructured('system_status', const {});
  check(
    label,
    'system_status',
    status['status'] == 'running',
    'status=${status['status']} apiServerVersion='
        '${status['apiServerVersion']} cliVersion=${status['cliVersion']} '
        'versionSupported=${status['versionSupported']}',
  );

  final projects = await channel.callStructured('project_list', const {});
  final projectList = (projects['projects'] as List?) ?? const [];
  check(
    label,
    'project_list',
    projects.containsKey('projects'),
    'projects=${projectList.length}',
  );

  // Full image list via pagination (default limit is 50; walk all pages).
  var offset = 0;
  var total = -1;
  var collected = 0;
  var pages = 0;
  while (true) {
    final page = await channel.callStructured('image_list', <String, dynamic>{
      'limit': 50,
      'offset': offset,
    });
    final images = (page['images'] as List?) ?? const [];
    total = page['total'] as int? ?? -1;
    collected += images.length;
    pages++;
    if (page['hasMore'] != true) break;
    offset = page['nextOffset'] as int? ?? (offset + images.length);
  }
  check(
    label,
    'image_list',
    total >= 0 && collected == total,
    'total=$total collected=$collected pages=$pages',
  );
}

Future<void> _concurrency(Channel channel, String label, Check check) async {
  await channel.initialize();
  final results = await Future.wait(
    List.generate(
      5,
      (_) => channel.callStructured('system_status', const {}),
    ),
  );
  final canonical = results.map(jsonEncode).toSet();
  check(
    label,
    'concurrent-system_status-x5',
    results.length == 5 && canonical.length == 1,
    'distinct=${canonical.length} of 5; sample=${canonical.first}',
  );
}

Future<void> _pagination(Channel channel, String label, Check check) async {
  await channel.initialize();

  Future<Set<String>> walk(String tool, String listKey, String idKey) async {
    const limit = 7; // deliberately small to force many pages
    var offset = 0;
    var total = -1;
    final seen = <String>{};
    var pages = 0;
    var overlap = 0;
    var orderViolations = 0;
    String? previous;
    while (true) {
      final page = await channel.callStructured(tool, <String, dynamic>{
        'limit': limit,
        'offset': offset,
      });
      final items = (page[listKey] as List).cast<Map<String, dynamic>>();
      total = page['total'] as int;
      final returned = page['returned'] as int? ?? items.length;
      if (returned != items.length) {
        check(
          label,
          '$tool.returned-field',
          false,
          'page $pages: returned=$returned items=${items.length}',
        );
      }
      for (final item in items) {
        final id = item[idKey] as String;
        if (!seen.add(id)) overlap++;
        if (previous != null && id.compareTo(previous) < 0) {
          orderViolations++;
        }
        previous = id;
      }
      pages++;
      final hasMore = page['hasMore'] as bool;
      final nextOffset = page['nextOffset'];
      if (!hasMore) {
        check(
          label,
          '$tool.last-page',
          nextOffset == null,
          'last page hasMore=false nextOffset=$nextOffset',
        );
        break;
      }
      if (nextOffset is! int || nextOffset <= offset) {
        check(
          label,
          '$tool.nextOffset-progress',
          false,
          'page $pages offset=$offset nextOffset=$nextOffset',
        );
        break;
      }
      offset = nextOffset;
      if (pages > 100) {
        check(label, '$tool.walk-bounded', false, 'exceeded 100 pages');
        break;
      }
    }
    check(
      label,
      '$tool.walk',
      overlap == 0 && orderViolations == 0 && seen.length == total,
      'total=$total walked=${seen.length} pages=$pages '
          'overlap=$overlap orderViolations=$orderViolations (limit=$limit)',
    );
    return seen;
  }

  final mcpImages = await walk('image_list', 'images', 'reference');
  final mcpContainers = await walk('container_list', 'containers', 'name');

  // Cross-check against the container CLI (GUI 对照的 CLI 等价物)。集合级
  // 核对：MCP（XPC）与 CLI 对同一运行时的视图必须互相解释得通。
  // 已知差异：CLI 的 `image ls` 会隐藏 Apple 内部基础设施镜像（builder
  // shim、vminit），XPC 视图包含它们——允许 MCP 多出且仅多出这类镜像。
  final cliImages = await Process.run('container', <String>[
    'image',
    'ls',
    '--format',
    'json',
  ]);
  final cliContainers = await Process.run('container', <String>[
    'ls',
    '-a',
    '--format',
    'json',
  ]);
  if (cliImages.exitCode == 0 && cliContainers.exitCode == 0) {
    bool isInternalImage(String ref) =>
        ref.startsWith('ghcr.io/apple/container-builder-shim/') ||
        ref.startsWith('ghcr.io/apple/containerization/vminit');
    final cliImageSet = <String>{
      for (final i in jsonDecode(cliImages.stdout as String) as List)
        ((i as Map)['configuration'] as Map)['name'] as String,
    };
    final cliContainerSet = <String>{
      for (final c in jsonDecode(cliContainers.stdout as String) as List)
        ((c as Map)['configuration'] as Map)['id'] as String,
    };
    final missingImages = cliImageSet.difference(mcpImages);
    final extraImages = mcpImages.difference(cliImageSet);
    final unexplainedExtra = extraImages.where((r) => !isInternalImage(r));
    check(
      label,
      'cli-cross-check.images',
      missingImages.isEmpty && unexplainedExtra.isEmpty,
      'mcp=${mcpImages.length} cli=${cliImageSet.length} '
          'missingInMcp=${missingImages.length} '
          'extraInMcp=${extraImages.length}'
          '${extraImages.isEmpty ? '' : ' ${extraImages.toList()..sort()}'}',
    );
    final missingContainers = cliContainerSet.difference(mcpContainers);
    final extraContainers = mcpContainers.difference(cliContainerSet);
    check(
      label,
      'cli-cross-check.containers',
      missingContainers.isEmpty && extraContainers.isEmpty,
      'mcp=${mcpContainers.length} cli=${cliContainerSet.length} '
          'missingInMcp=$missingContainers extraInMcp=$extraContainers',
    );
  } else {
    check(
      label,
      'cli-cross-check',
      false,
      'container CLI failed: ${cliImages.stderr} ${cliContainers.stderr}',
    );
  }
}

Future<void> _helpModes(Channel channel, String label, Check check) async {
  await channel.initialize();

  Future<Map<String, dynamic>> raw(Map<String, dynamic> arguments) async {
    try {
      final result = await channel.request('tools/call', <String, dynamic>{
        'name': 'gcm_help',
        'arguments': arguments,
      });
      return result;
    } on StateError catch (error) {
      // 协议层错误（如 -32602 参数校验失败）也作为证据记录，不中断探测。
      return <String, dynamic>{'protocolError': error.message};
    }
  }

  // Mode 1: default (no args).
  final defaultResult = await raw(const {});
  final defaultStructured = (defaultResult['structuredContent'] as Map)
      .cast<String, dynamic>();
  final domains = (defaultStructured['domains'] as Map).cast<String, dynamic>();
  final domainKeys = domains.keys.toList()..sort();
  check(
    label,
    'help.default',
    defaultResult['isError'] != true && domains.isNotEmpty,
    'totalTools=${defaultStructured['totalTools']} domains=$domainKeys',
  );

  // Mode 2: domain filter.
  final domainResult = await raw(const <String, dynamic>{
    'domain': 'container',
  });
  final domainStructured = (domainResult['structuredContent'] as Map)
      .cast<String, dynamic>();
  final containerDomains = (domainStructured['domains'] as Map)
      .cast<String, dynamic>();
  check(
    label,
    'help.domain',
    domainResult['isError'] != true &&
        containerDomains.keys.toSet().length == 1 &&
        containerDomains.containsKey('container'),
    'domains=${containerDomains.keys.toList()} tools='
        '${(containerDomains['container'] as List).length}',
  );

  // Mode 3: single-tool detail (issue #30 acceptance).
  final toolResult = await raw(const <String, dynamic>{
    'tool': 'container_create',
  });
  final toolStructured = toolResult['structuredContent'];
  final toolOk =
      toolResult['isError'] != true &&
      toolStructured is Map &&
      toolStructured['name'] == 'container_create';
  check(
    label,
    'help.tool-mode',
    toolOk,
    toolOk
        ? 'tool mode OK'
        : 'isError=${toolResult['isError']} '
              'protocolError=${toolResult['protocolError']} body='
              '${jsonEncode(toolStructured ?? toolResult['content'])}',
  );

  // catalogRevision presence (issue #30 acceptance).
  check(
    label,
    'help.catalogRevision',
    defaultStructured.containsKey('catalogRevision'),
    'catalogRevision=${defaultStructured['catalogRevision']}',
  );

  // domain+tool 同传应拒绝（issue #30）。
  final bothResult = await raw(const <String, dynamic>{
    'domain': 'container',
    'tool': 'container_create',
  });
  check(
    label,
    'help.domain+tool-rejected',
    bothResult['isError'] == true || bothResult['protocolError'] != null,
    'isError=${bothResult['isError']} '
        'protocolError=${bothResult['protocolError']} '
        'error=${bothResult['error']}',
  );
}
