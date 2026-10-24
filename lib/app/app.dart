/// 应用根：构建 Service/Controller 层并按就绪状态分级路由
/// （onboarding.md §4 方案 C）：
/// - 阻塞级（未安装/版本过低/主版本不兼容）→ 全窗 OnboardingPage
///   （带「跳过并仅查看设置」出口）；
/// - 其余 → AppShell（自修复级在壳内显示降级横幅）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/container_bridge.dart';
import '../bridge/method_channel_container_bridge.dart';
import '../features/settings/mcp_settings_controller.dart';
import '../features/system/onboarding_page.dart';
import '../features/system/readiness_controller.dart';
import '../launcher/maclauncher_bridge.dart';
import '../services/compose_service.dart';
import '../services/container_service.dart';
import '../services/image_service.dart';
import '../services/mount_service.dart';
import '../services/network_service.dart';
import '../services/system_service.dart';
import 'app_shell.dart';
import 'menu_bar_controller.dart';

class GhostContainerManagerApp extends StatefulWidget {
  const GhostContainerManagerApp({
    super.key,
    this.bridge,
    this.debugBypass = false,
    this.enableMcp = true,
    this.enableLauncher = true,
    this.menuBarChannel,
  });

  /// 测试注入点：fake 桥接；缺省用 MethodChannel 真实桥接。
  final ContainerBridge? bridge;

  /// GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME（仅 debug 构建传入）。
  final bool debugBypass;

  /// 是否按设置启动 MCP server（测试关闭以避免绑定真实端口）。
  final bool enableMcp;

  /// 是否连接 MacLauncher（测试关闭以避免触碰真实 SDK/主机进程）。
  final bool enableLauncher;

  /// 测试注入点；生产环境由 macOS AppKit 实现状态栏和偏好持久化。
  final MenuBarChannel? menuBarChannel;

  @override
  State<GhostContainerManagerApp> createState() =>
      _GhostContainerManagerAppState();
}

class _GhostContainerManagerAppState extends State<GhostContainerManagerApp> {
  late final SystemService _systemService;
  late final ContainerService _containerService;
  late final ImageService _imageService;
  late final MountService _mountService;
  late final NetworkService _networkService;
  late final ComposeService _composeService;
  late final ReadinessController _readiness;
  late final McpSettingsController _mcp;
  late final MenuBarController _menuBar;
  MacLauncherBridge? _launcher;
  late final Future<void> _menuInitialization;

  /// 「跳过并仅查看设置」出口（本次会话内有效，不持久化）。
  bool _skipToSettings = false;

  @override
  void initState() {
    super.initState();
    final bridge = widget.bridge ?? MethodChannelContainerBridge();
    _systemService = SystemService(
      bridge: bridge,
      debugBypassEnabled: widget.debugBypass,
    );
    _containerService = ContainerService(bridge: bridge);
    _imageService = ImageService(
      bridge: bridge,
      containerService: _containerService,
    );
    _mountService = MountService(containerService: _containerService);
    _networkService = NetworkService(
      bridge: bridge,
      containerService: _containerService,
    );
    _composeService = ComposeService(
      bridge: bridge,
      containerService: _containerService,
    );
    _readiness = ReadinessController(
      systemService: _systemService,
      bridge: bridge,
    );
    _mcp = McpSettingsController(
      systemService: _systemService,
      containerService: _containerService,
      imageService: _imageService,
      mountService: _mountService,
      networkService: _networkService,
      composeService: _composeService,
    );
    unawaited(_readiness.refresh());
    _menuBar = MenuBarController(
      containers: _containerService,
      channel: widget.menuBarChannel,
    );
    _menuInitialization = _menuBar.initialize();
    if (widget.enableMcp) {
      unawaited(_mcp.sync());
    }
    if (widget.enableLauncher) {
      // MacLauncher 是可选集成：未安装或连接失败不影响主功能。
      final launcher = MacLauncherBridge(containers: _containerService);
      _launcher = launcher;
      unawaited(
        launcher.connect().catchError((Object error, StackTrace stack) {
          debugPrint('MacLauncher connect failed (ignored): $error');
        }),
      );
    }
  }

  @override
  void dispose() {
    // E04: shut owned resources down in order — MCP server first (stops
    // serving tool calls), then the container polling service, then the
    // readiness controller. McpSettingsController keeps its own ownership;
    // the public switch stops the server without reaching into settings.
    unawaited(_mcp.setEnabled(false));
    _menuBar.dispose();
    // 先断开 MacLauncher（取消在飞日志、关闭 SDK），再停容器服务。
    unawaited(_launcher?.dispose());
    unawaited(_containerService.dispose());
    _readiness.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostContainerManager',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: ListenableBuilder(
        listenable: _readiness,
        builder: (context, _) {
          final readiness = _readiness.readiness;
          if (readiness == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final blocking =
              !_skipToSettings &&
              switch (readiness.level) {
                ReadinessLevel.notInstalled ||
                ReadinessLevel.versionTooLow ||
                ReadinessLevel.unsupportedMajor => true,
                _ => false,
              };
          if (blocking) {
            return OnboardingPage(
              controller: _readiness,
              onSkipToSettings: () => setState(() => _skipToSettings = true),
            );
          }
          return FutureBuilder<void>(
            future: _menuInitialization,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              final startPage = _skipToSettings
                  ? '设置'
                  : _menuBar.defaultStartPage;
              return AppShell(
                readiness: _readiness,
                mcp: _mcp,
                menuBar: _menuBar,
                containers: _containerService,
                images: _imageService,
                mounts: _mountService,
                networks: _networkService,
                compose: _composeService,
                initialIndex: kSidebarItems.indexOf(startPage),
              );
            },
          );
        },
      ),
    );
  }
}
