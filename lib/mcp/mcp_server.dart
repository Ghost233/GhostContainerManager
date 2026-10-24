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
import 'tools/compose_tools.dart';
import 'tools/container_tools.dart';
import 'tools/image_tools.dart';
import 'tools/mount_tools.dart';
import 'tools/network_tools.dart';
import 'tools/project_tools.dart';
import 'tools/registry_tools.dart';
import 'tools/system_tools.dart';

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
    title: 'GhostContainerManager',
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

  /// Builds a protocol server with every tool domain registered. Exposed so
  /// the stdio path and tests can attach their own transports.
  McpServer buildServer() {
    final server = AuditedMcpServer(
      serverInfo,
      auditor: auditor,
      options: McpServerOptions(
        instructions:
            'Manages the local Apple container runtime on macOS. '
            'system_* tools report and control runtime state; container_* '
            'tools query and manage containers; image_* tools manage '
            'images (pull/delete are slow or destructive); mount_*/'
            'network_* tools are read-only views; compose_* tools run '
            'the compose plugin (up/down change real resources); '
            'project_* tools manage project workflows (build/test/reclaim '
            'change real resources); registry_* tools manage the local '
            'registry container. Confirm '
            'with the user before calling tools annotated '
            'destructiveHint: true.',
      ),
    );
    registerSystemTools(server, _systemService);
    registerContainerTools(server, _containerService);
    final image = _imageService;
    if (image != null) registerImageTools(server, image);
    final mount = _mountService;
    if (mount != null) registerMountTools(server, mount);
    final network = _networkService;
    if (network != null) registerNetworkTools(server, network);
    final compose = _composeService;
    if (compose != null) registerComposeTools(server, compose);
    final project = _projectService;
    if (project != null) registerProjectTools(server, project);
    final registry = _registryService;
    if (registry != null) registerRegistryTools(server, registry);
    return server;
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
