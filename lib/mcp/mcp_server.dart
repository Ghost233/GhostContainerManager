/// In-app MCP server (docs/spec/mcp-tools.md §1/§2).
///
/// Same-process design: tools call the Service layer directly (no HTTP
/// self-loop). Transports: Streamable HTTP on 127.0.0.1 (default port 35731)
/// plus a stdio thin proxy (`stdio_proxy.dart`) that forwards newline-
/// delimited JSON-RPC to the HTTP endpoint.
library;

// Public named parameter `systemService` keeps its name; the
// initializing-formals lint cannot apply to private fields.
// ignore_for_file: prefer_initializing_formals

import 'package:mcp_dart/mcp_dart.dart';

import '../services/compose_service.dart';
import '../services/container_service.dart';
import '../services/image_service.dart';
import '../services/mount_service.dart';
import '../services/network_service.dart';
import '../services/project_service.dart';
import '../services/registry_service.dart';
import '../services/system_service.dart';
import 'tool_audit.dart';
import 'tool_registrar.dart';
import 'tools/catalog_tools.dart';

/// MCP server embedded in the app. Lifecycle follows the app (start on
/// launch when enabled in settings; stop on quit).
class GcmMcpServer {
  GcmMcpServer({
    required SystemService systemService,
    required ContainerService containerService,
    ImageService? imageService,
    MountService? mountService,
    NetworkService? networkService,
    ComposeService? composeService,
    ProjectService? projectService,
    RegistryService? registryService,
    this.host = '127.0.0.1',
    this.port = defaultPort,
    this.path = '/mcp',
    this.enableJsonResponse = false,
    McpToolAuditor? auditor,
  }) : _systemService = systemService,
       _containerService = containerService,
       _imageService = imageService,
       _mountService = mountService,
       _networkService = networkService,
       _composeService = composeService,
       _projectService = projectService,
       _registryService = registryService,
       auditor = auditor ?? McpToolAuditor();

  /// Default MCP HTTP port (settings page default, issue #16 验收 4).
  static const int defaultPort = 35731;

  static const Implementation serverInfo = Implementation(
    name: 'ghost-container-manager',
    title: 'Ghost Container Manager',
    version: '0.0.0',
  );

  final SystemService _systemService;
  final ContainerService _containerService;

  /// Optional tool domains; null = not registered (tests, partial wiring).
  final ImageService? _imageService;
  final MountService? _mountService;
  final NetworkService? _networkService;
  final ComposeService? _composeService;
  final ProjectService? _projectService;
  final RegistryService? _registryService;

  /// Bounded record of tool calls, shared across transport sessions so the
  /// settings page keeps a stable short history (issue #16).
  final McpToolAuditor auditor;

  /// Newest-first snapshot for the settings page.
  List<McpCallRecord> get recentCalls => auditor.records;

  final String host;
  final int port;
  final String path;

  /// Test hook: return plain JSON responses instead of SSE streams.
  final bool enableJsonResponse;

  StreamableMcpServer? _transport;

  /// Port actually bound (differs from [port] when port 0 was requested).
  int get boundPort => _transport?.boundPort ?? port;

  bool get running => _transport != null;

  /// Builds a protocol server with the slim two-tool surface registered.
  /// Exposed so the stdio path and tests can attach their own transports.
  ///
  /// 精简注册模式（2026-10-26 用户拍板）：tools/list 只暴露 gcm_help 与
  /// gcm_call；35 个业务工具收集进 [ToolCallbackRegistry]，由 gcm_call
  /// 按名分发。业务工具的 callback 仍经 AuditedMcpServer 审计包装——
  /// 分发时调用的是 registry 里未包装的原始 callback，审计由 gcm_call
  /// 自身注册时的包装覆盖（记录名为 gcm_call；工具粒度的审计见
  /// [GcmMcpServer._auditedRegistry]）。
  McpServer buildServer() {
    final server = AuditedMcpServer(
      serverInfo,
      auditor: auditor,
      options: McpServerOptions(
        instructions:
            'Manages the local Apple container runtime on macOS. This server '
            'exposes exactly two tools: gcm_help lists every available '
            'management tool (grouped by domain, with parameters and risk '
            'annotations), and gcm_call invokes one of them by name. Always '
            'call gcm_help first to discover tool names and arguments. '
            'Confirm with the user before calling tools whose catalog entry '
            'has destructiveHint: true.',
      ),
    );
    registerCatalogTools(server, _auditedRegistry(server));
    return server;
  }

  /// Collects business-tool callbacks, wrapping each with the same audit
  /// record the direct-registration path produced (tool name, success,
  /// duration — no arguments/results).
  ToolCallbackRegistry _auditedRegistry(AuditedMcpServer server) {
    final raw = buildBusinessToolRegistry(
      systemService: _systemService,
      containerService: _containerService,
      imageService: _imageService,
      mountService: _mountService,
      networkService: _networkService,
      composeService: _composeService,
      projectService: _projectService,
      registryService: _registryService,
    );
    final audited = ToolCallbackRegistry();
    for (final entry in raw.callbacks.entries) {
      audited.callbacks[entry.key] = (args, extra) async {
        final startedAt = DateTime.now();
        final stopwatch = Stopwatch()..start();
        var succeeded = false;
        try {
          final result = await entry.value(args, extra);
          succeeded = !result.isError;
          return result;
        } finally {
          stopwatch.stop();
          auditor.record(
            tool: entry.key,
            startedAt: startedAt,
            succeeded: succeeded,
            duration: stopwatch.elapsed,
          );
        }
      };
    }
    return audited;
  }

  /// Starts the Streamable HTTP transport on 127.0.0.1.
  Future<void> start() async {
    if (_transport != null) {
      throw StateError('MCP server already started');
    }
    final transport = StreamableMcpServer(
      serverFactory: (_) => buildServer(),
      host: host,
      port: port,
      path: path,
      enableJsonResponse: enableJsonResponse,
    );
    await transport.start();
    _transport = transport;
  }

  Future<void> stop() async {
    final transport = _transport;
    _transport = null;
    await transport?.stop();
  }
}
