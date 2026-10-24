import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/mcp/tools/project_tools.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/project_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

void main() {
  late McpServer server;
  late StreamableMcpServer transport;
  late HttpClient client;
  late _FakeProjectService projects;
  late _SseCollector events;
  Uri? uri;
  String? sessionId;
  var requestId = 0;

  setUp(() async {
    projects = _FakeProjectService();
    server = McpServer(
      const Implementation(name: 'project-tools-test', version: '1.0.0'),
    );
    transport = StreamableMcpServer(
      host: InternetAddress.loopbackIPv4.address,
      port: 0,
      path: '/mcp',
      serverFactory: (_) {
        registerProjectTools(server, projects);
        return server;
      },
      enableJsonResponse: true,
    );
    await transport.start();
    uri = Uri.parse('http://127.0.0.1:${transport.boundPort}/mcp');
    client = HttpClient()..maxConnectionsPerHost = 8;
    events = _SseCollector();
    sessionId = null;
    requestId = 0;
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
    final httpRequest = await client.postUrl(uri!);
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
          events.progress.add(event);
        }
        if (event['id'] == actualId) responseMessage = event;
      }
      if (responseMessage == null) {
        throw StateError('No JSON-RPC response in SSE stream');
      }
      decoded = responseMessage;
    } else {
      final body = await utf8.decodeStream(response);
      decoded = jsonDecode(body) as Map<String, dynamic>;
    }
    if (decoded['error'] != null) throw StateError('${decoded['error']}');
    return decoded['result'] as Map<String, dynamic>;
  }

  Future<void> notify(String method, Map<String, dynamic> params) async {
    final httpRequest = await client.postUrl(uri!);
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

  Future<void> initialize() async {
    await request('initialize', <String, dynamic>{
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{'name': 'test', 'version': '1.0.0'},
    });
    await notify('notifications/initialized', <String, dynamic>{});
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments, {
    int? id,
    String? progressToken,
  }) {
    return request('tools/call', <String, dynamic>{
      'name': name,
      'arguments': arguments,
      if (progressToken != null)
        '_meta': <String, dynamic>{'progressToken': progressToken},
    }, id: id);
  }

  Future<List<dynamic>> listTools() async {
    final result = await request('tools/list', <String, dynamic>{});
    return result['tools'] as List<dynamic>;
  }

  test('list/get/init return curated structured content', () async {
    await initialize();
    final listed = await callTool('project_list', <String, dynamic>{});
    expect((listed['structuredContent'] as Map)['projects'], hasLength(1));
    final got = await callTool('project_get', <String, dynamic>{
      'project': 'myapp',
    });
    expect((got['structuredContent'] as Map)['project'], 'myapp');
    expect(
      ((got['structuredContent'] as Map)['images'] as List).single['inUse'],
      isTrue,
    );
    final initialized = await callTool('project_init', <String, dynamic>{
      'path': '/tmp/demo',
    });
    expect((initialized['structuredContent'] as Map)['prefix'], 'demo');
  });

  test(
    'build defaults to skipping tests and forwards bounded progress',
    () async {
      await initialize();
      final result = await callTool('project_build', <String, dynamic>{
        'project': 'myapp',
        'name': 'web',
        'buildArgs': <String, dynamic>{'MODE': 'release'},
        'noCache': true,
      }, progressToken: 'build-progress');
      expect(result['isError'], isNot(true));
      expect(projects.lastSkipTests, isTrue);
      expect(projects.lastBuildArgs, <String, String>{'MODE': 'release'});
      expect(projects.lastNoCache, isTrue);
      final data = result['structuredContent'] as Map<String, dynamic>;
      expect(data['image'], 'myapp-web:latest');
      expect(data.containsKey('testsPassed'), isFalse);
      await events.waitForProgress();
      expect(events.progress, isNotEmpty);
      expect(
        events.progress.first['params']['progressToken'],
        'build-progress',
      );
    },
  );

  test('failed build returns tail output and its durable log path', () async {
    projects.buildResult = const ProjectBuildResult(
      project: 'myapp',
      image: 'myapp-web:latest',
      exitCode: 7,
      durationMs: 20,
      output: 'last lines',
      failureLogPath: '/tmp/myapp-build.log',
    );
    await initialize();
    final result = await callTool('project_build', <String, dynamic>{
      'project': 'myapp',
      'name': 'web',
    });
    expect(result['isError'], isNot(true));
    final data = result['structuredContent'] as Map<String, dynamic>;
    expect(data['exitCode'], 7);
    expect(data['output'], 'last lines');
    expect(data['failureLogPath'], '/tmp/myapp-build.log');
  });

  test(
    'test command is required and a nonzero exit remains result data',
    () async {
      projects.testResult = const ProjectTestResult(
        project: 'myapp',
        image: 'myapp-web:latest',
        exitCode: 3,
        stdout: 'out',
        stderr: 'failed',
        truncated: false,
        durationMs: 9,
      );
      await initialize();
      final result = await callTool('project_test', <String, dynamic>{
        'project': 'myapp',
        'name': 'web',
        'command': <String>['sh', '-c', 'exit 3'],
      });
      expect(result['isError'], isNot(true));
      expect(projects.lastCommand, <String>['sh', '-c', 'exit 3']);
      final data = result['structuredContent'] as Map<String, dynamic>;
      expect(data['exitCode'], 3);
      expect(data['stderr'], 'failed');
    },
  );

  test('reclaim forwards dryRun and returns the shared report shape', () async {
    await initialize();
    final result = await callTool('project_reclaim', <String, dynamic>{
      'project': 'myapp',
      'dryRun': true,
    });
    expect(result['isError'], isNot(true));
    expect(projects.lastDryRun, isTrue);
    final data = result['structuredContent'] as Map<String, dynamic>;
    expect(data['project'], 'myapp');
    expect(data['containers'], isA<Map<String, dynamic>>());
    expect(data['images'], isA<Map<String, dynamic>>());
    expect(data['disk']['reclaimedBytes'], 0);
  });

  test(
    'publish and restore expose registry references and deleteLocal',
    () async {
      await initialize();
      final published = await callTool('project_publish', <String, dynamic>{
        'project': 'myapp',
        'name': 'web',
        'deleteLocal': true,
      });
      expect(projects.lastDeleteLocal, isTrue);
      expect(
        (published['structuredContent'] as Map)['pushed'].single['target'],
        '127.0.0.1:5056/myapp-web:latest',
      );
      final restored = await callTool('project_restore', <String, dynamic>{
        'project': 'myapp',
        'name': 'web',
      });
      expect(
        (restored['structuredContent'] as Map)['restored'].single['reference'],
        'myapp-web:latest',
      );
    },
  );

  test('all eight tools expose honest annotations and input schemas', () async {
    await initialize();
    final tools = await listTools();
    final byName = <String, Map<String, dynamic>>{
      for (final tool in tools)
        tool['name'] as String: tool.cast<String, dynamic>(),
    };
    expect(
      byName.keys,
      containsAll(<String>[
        'project_list',
        'project_get',
        'project_init',
        'project_build',
        'project_test',
        'project_reclaim',
        'project_publish',
        'project_restore',
      ]),
    );
    for (final name in byName.keys) {
      expect(byName[name]!['annotations']['openWorldHint'], isTrue);
    }
    expect(byName['project_list']!['annotations']['readOnlyHint'], isTrue);
    expect(byName['project_get']!['annotations']['readOnlyHint'], isTrue);
    expect(
      byName['project_reclaim']!['annotations']['destructiveHint'],
      isTrue,
    );
    expect(byName['project_reclaim']!['annotations']['idempotentHint'], isTrue);
    expect(byName['project_build']!['annotations']['idempotentHint'], isFalse);
    expect(byName['project_test']!['annotations']['idempotentHint'], isFalse);
    final build = byName['project_build']!;
    final buildProperties = build['inputSchema']['properties'] as Map;
    expect(buildProperties, isNot(contains('command')));
    expect(buildProperties['skipTests']['default'], isTrue);
    expect(
      byName['project_test']!['inputSchema']['required'],
      contains('command'),
    );
  });

  test('business failures become tool errors, not protocol errors', () async {
    projects.error = GcmException(GcmErrorCode.conflict, '项目正在构建');
    await initialize();
    final result = await callTool('project_get', <String, dynamic>{
      'project': 'myapp',
    });
    expect(result['isError'], isTrue);
    expect(
      ((result['structuredContent'] as Map)['error'] as Map)['code'],
      'CONFLICT',
    );
  });

  test('request cancellation reaches the Service operation', () async {
    projects.waitForBuildCancellation = true;
    await initialize();
    final pending = callTool('project_build', <String, dynamic>{
      'project': 'myapp',
      'name': 'web',
    }, id: 900);
    // mcp_dart deliberately sends no response once a request is aborted.
    // The forced client close in tearDown settles this HTTP future.
    pending.ignore();
    await projects.buildStarted.future.timeout(const Duration(seconds: 2));
    await notify('notifications/cancelled', <String, dynamic>{
      'requestId': 900,
      'reason': 'test cancellation',
    }).timeout(const Duration(seconds: 2));
    await projects.buildCancelled.future.timeout(const Duration(seconds: 2));
  });
}

class _FakeProjectService implements ProjectService {
  final calls = <String>[];
  Object? error;
  bool? lastSkipTests;
  bool? lastNoCache;
  bool? lastDeleteLocal;
  bool? lastDryRun;
  Map<String, String>? lastBuildArgs;
  List<String>? lastCommand;
  bool waitForBuildCancellation = false;
  final buildCancelled = Completer<void>();
  final buildStarted = Completer<void>();

  ProjectBuildResult buildResult = const ProjectBuildResult(
    project: 'myapp',
    image: 'myapp-web:latest',
    exitCode: 0,
    durationMs: 10,
  );
  ProjectTestResult testResult = const ProjectTestResult(
    project: 'myapp',
    image: 'myapp-web:latest',
    exitCode: 0,
    stdout: 'ok\n',
    stderr: '',
    truncated: false,
    durationMs: 5,
  );

  void _throwError() {
    final value = error;
    if (value != null) throw value;
  }

  @override
  Future<List<ProjectSummary>> listProjects() async {
    _throwError();
    return const <ProjectSummary>[
      ProjectSummary(
        project: 'myapp',
        path: '/tmp/myapp',
        images: <String>['myapp-web:latest'],
        containers: 1,
      ),
    ];
  }

  @override
  Future<ProjectDetails> getProject({String? project, String? path}) async {
    _throwError();
    return const ProjectDetails(
      project: 'myapp',
      path: '/tmp/myapp',
      images: <ProjectImageStatus>[
        ProjectImageStatus(reference: 'myapp-web:latest', inUse: true),
      ],
      containers: [],
    );
  }

  @override
  Future<ProjectInitResult> initProject({
    required String path,
    String? prefix,
  }) async {
    _throwError();
    return ProjectInitResult(path: path, prefix: prefix ?? 'demo');
  }

  @override
  Future<ProjectBuildResult> buildProject({
    String? project,
    String? path,
    required String name,
    String? dockerfile,
    String? context,
    Map<String, String> buildArgs = const <String, String>{},
    bool skipTests = true,
    List<String>? testCommand,
    bool noCache = false,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    lastSkipTests = skipTests;
    lastBuildArgs = buildArgs;
    lastNoCache = noCache;
    onProgress?.call('#1 building');
    if (waitForBuildCancellation) {
      buildStarted.complete();
      await cancellation!.first;
      if (!buildCancelled.isCompleted) buildCancelled.complete();
      throw GcmException(GcmErrorCode.internal, '项目构建已取消');
    }
    _throwError();
    return buildResult;
  }

  @override
  Future<ProjectTestResult> testProject({
    String? project,
    String? path,
    required String name,
    required List<String> command,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    lastCommand = command;
    _throwError();
    return testResult;
  }

  @override
  Future<ProjectPublishResult> publishProject({
    String? project,
    String? path,
    required String name,
    bool deleteLocal = false,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    lastDeleteLocal = deleteLocal;
    onProgress?.call('pushing');
    _throwError();
    return const ProjectPublishResult(
      project: 'myapp',
      pushed: <ProjectPushResult>[
        ProjectPushResult(
          source: 'myapp-web:latest',
          target: '127.0.0.1:5056/myapp-web:latest',
          sizeBytes: 100,
        ),
      ],
    );
  }

  @override
  Future<ProjectRestoreResult> restoreProject({
    String? project,
    String? path,
    required String name,
    void Function(String line)? onProgress,
    Stream<void>? cancellation,
  }) async {
    onProgress?.call('pulling');
    _throwError();
    return const ProjectRestoreResult(
      project: 'myapp',
      restored: <ProjectRestoredImage>[
        ProjectRestoredImage(reference: 'myapp-web:latest'),
      ],
    );
  }

  @override
  Future<ProjectReclaimReport> reclaimProject({
    String? project,
    String? path,
    bool dryRun = false,
  }) async {
    lastDryRun = dryRun;
    _throwError();
    return const ProjectReclaimReport(
      project: 'myapp',
      stoppedContainers: <String>[],
      deletedContainers: <String>[],
      failedContainers: <String>[],
      deletedImages: <String>[],
      retainedImages: <ProjectRetainedImage>[],
      skippedExternalImages: <ProjectExternalImage>[],
      disk: ProjectDiskReport(beforeBytes: 0, afterBytes: 0, reclaimedBytes: 0),
      errors: <String>[],
    );
  }
}

class _SseCollector {
  final progress = <Map<String, dynamic>>[];

  Future<void> waitForProgress() async {
    for (var index = 0; index < 100 && progress.isEmpty; index += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
