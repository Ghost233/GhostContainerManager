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
import '../services/compose_service.dart';
import '../services/container_service.dart';
import '../services/image_service.dart';
import '../services/mount_service.dart';
import '../services/network_service.dart';
import '../services/system_service.dart';
import 'app_shell.dart';

class GhostContainerManagerApp extends StatefulWidget {
  const GhostContainerManagerApp({
    super.key,
    this.bridge,
    this.debugBypass = false,
    this.enableMcp = true,
  });

  /// 测试注入点：fake 桥接；缺省用 MethodChannel 真实桥接。
  final ContainerBridge? bridge;

  /// GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME（仅 debug 构建传入）。
  final bool debugBypass;

  /// 是否按设置启动 MCP server（测试关闭以避免绑定真实端口）。
  final bool enableMcp;

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
    _imageService = ImageService(bridge: bridge);
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
    if (widget.enableMcp) {
      unawaited(_mcp.sync());
    }
  }

  @override
  void dispose() {
    // E04: shut owned resources down in order — MCP server first (stops
    // serving tool calls), then the container polling service, then the
    // readiness controller. McpSettingsController keeps its own ownership;
    // the public switch stops the server without reaching into settings.
    unawaited(_mcp.setEnabled(false));
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
          return AppShell(
            readiness: _readiness,
            mcp: _mcp,
            containers: _containerService,
            images: _imageService,
            mounts: _mountService,
            networks: _networkService,
            compose: _composeService,
            initialIndex: _skipToSettings ? kSidebarItems.indexOf('设置') : 0,
          );
        },
      ),
    );
  }
}
