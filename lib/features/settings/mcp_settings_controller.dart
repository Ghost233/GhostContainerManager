/// Settings-side controller for the in-app MCP server block
/// (issue #16 验收 4；ui-ia.md D9）。
///
/// Owns the [GcmMcpServer] lifecycle (start/stop/restart on port change) and
/// exposes presentation state for the settings page. The server instance is
/// created lazily so a port edit takes effect on the next start.
///
/// 注意：「最近 MCP 调用简表」的数据由 [GcmMcpServer.auditor] 记录，本控制器
/// 只暴露只读快照并在有新调用时 notifyListeners。
library;

// Public named parameters keep their names; the initializing-formals lint
// cannot apply to private fields (same pattern as mcp_server.dart).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mcp/mcp_server.dart';
import '../../mcp/tool_audit.dart';
import '../../services/compose_service.dart';
import '../../services/container_service.dart';
import '../../services/image_service.dart';
import '../../services/mount_service.dart';
import '../../services/network_service.dart';
import '../../services/system_service.dart';

class McpSettingsController extends ChangeNotifier {
  McpSettingsController({
    required SystemService systemService,
    required ContainerService containerService,
    ImageService? imageService,
    MountService? mountService,
    NetworkService? networkService,
    ComposeService? composeService,
    McpToolAuditor? auditor,
  }) : _systemService = systemService,
       _containerService = containerService,
       _imageService = imageService,
       _mountService = mountService,
       _networkService = networkService,
       _composeService = composeService,
       _auditor = auditor ?? McpToolAuditor() {
    _auditorSub = _auditor.changes.listen((_) {
      if (!_disposed) notifyListeners();
    });
  }

  final SystemService _systemService;
  final ContainerService _containerService;
  final ImageService? _imageService;
  final MountService? _mountService;
  final NetworkService? _networkService;
  final ComposeService? _composeService;
  final McpToolAuditor _auditor;
  StreamSubscription<void>? _auditorSub;
  bool _disposed = false;
  GcmMcpServer? _server;

  /// 开关状态（MCP-first：默认开启）。
  bool enabled = true;

  /// 监听端口（issue #16：默认 35731）。
  int port = GcmMcpServer.defaultPort;

  bool running = false;

  /// 实际绑定端口（启动后有效）。
  int? boundPort;

  /// 最近一次启动/停止失败原因。
  String? lastError;

  /// Newest-first call history (bounded by [McpToolAuditor.capacity]).
  List<McpCallRecord> get recentCalls => _auditor.records;

  String get endpoint => 'http://127.0.0.1:${boundPort ?? port}/mcp';

  /// App 启动时按 [enabled] 初始同步一次。
  Future<void> sync() => enabled ? _start() : _stop();

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    notifyListeners();
    await sync();
  }

  Future<void> setPort(int value) async {
    if (port == value) return;
    port = value;
    notifyListeners();
    if (running) await _start(); // 运行中改端口 → 重启生效
  }

  Future<void> _start() async {
    await _stop();
    final server = GcmMcpServer(
      systemService: _systemService,
      containerService: _containerService,
      imageService: _imageService,
      mountService: _mountService,
      networkService: _networkService,
      composeService: _composeService,
      port: port,
      auditor: _auditor,
    );
    try {
      await server.start();
      _server = server;
      running = true;
      boundPort = server.boundPort;
      lastError = null;
    } catch (e) {
      running = false;
      boundPort = null;
      lastError = 'MCP server 启动失败：$e';
    }
    notifyListeners();
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    running = false;
    boundPort = null;
    await server?.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _auditorSub?.cancel();
    _auditorSub = null;
    super.dispose();
  }
}
