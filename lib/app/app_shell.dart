/// 三列工作台导航框架（ui-ia.md D1 方案 A；侧栏 224，9 项）。
///
/// 侧栏 = 资源类型 + 运行时 + 设置/MCP；内容区 = 当前页；
/// 检查器列留给后续列表任务（T1b 仅占位）。
/// 降级壳（onboarding.md §4 方案 C）：serviceNotRunning / kernelMissing
/// 时主界面可进，内容区顶部显示横幅 + 一键修复。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../features/compose/compose_page.dart';
import '../features/containers/containers_page.dart';
import '../features/images/images_page.dart';
import '../features/mounts/mounts_page.dart';
import '../features/networks/networks_page.dart';
import '../features/projects/projects_page.dart';
import '../features/settings/mcp_settings_controller.dart';
import '../features/settings/settings_page.dart';
import '../features/system/readiness_controller.dart';
import '../features/system/runtime_page.dart';
import '../../services/compose_service.dart';
import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../services/image_service.dart';
import '../../services/mount_service.dart';
import '../../services/network_service.dart';
import '../../services/project_service.dart';
import '../../services/system_service.dart';
import '../ui/colors.dart';
import '../ui/components.dart';
import '../ui/motion.dart';
import 'menu_bar_controller.dart';
import 'placeholders.dart';

/// 侧栏项（ui-ia.md #13 回填后的 9 项）。
const List<String> kSidebarItems = [
  '容器',
  '项目',
  'Compose 项目',
  '镜像',
  '挂载',
  '网络',
  '运行时',
  '设置',
  'MCP',
];

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.readiness,
    required this.mcp,
    required this.menuBar,
    required this.containers,
    required this.images,
    required this.mounts,
    required this.networks,
    required this.compose,
    required this.projects,
    this.initialIndex = 0,
  });

  final ReadinessController readiness;
  final McpSettingsController mcp;

  /// 状态栏菜单偏好及原生导航事件。
  final MenuBarController menuBar;

  /// 容器只读通路（T2a service，容器页消费其公开 API）。
  final ContainerService containers;

  /// T5 镜像通路（列表/inspect/pull/delete 页）。
  final ImageService images;

  /// T6 三个资源域服务（挂载/网络/Compose 页）。
  final MountService mounts;
  final NetworkService networks;
  final ComposeService compose;

  /// T8 项目工作流通路（项目页：镜像列表/构建/回收/registry）。
  final ProjectService projects;

  /// 初始选中项（跳过引导进入设置时使用 kSidebarItems.indexOf('设置')）。
  final int initialIndex;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _selected = widget.initialIndex;
  late final StreamSubscription<String> _navigationSubscription;

  @override
  void initState() {
    super.initState();
    _navigationSubscription = widget.menuBar.navigationRequests.listen(
      _handleNavigation,
    );
  }

  void _handleNavigation(String page) {
    if (mounted && kSidebarItems.contains(page)) {
      setState(() => _selected = kSidebarItems.indexOf(page));
    }
  }

  /// 侧栏项（带可选计数徽章）。
  Widget _sidebarItem(int index, {int? badge}) {
    return ListTile(
      title: Text(kSidebarItems[index]),
      dense: true,
      selected: index == _selected,
      trailing: badge == null ? null : CountBadge(count: badge),
      onTap: () => setState(() => _selected = index),
    );
  }

  @override
  void dispose() {
    unawaited(_navigationSubscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 224,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Material(
                color: GcmColors.surfaceSidebar(context),
                child: StreamBuilder<List<ContainerSnapshotInfo>>(
                  stream: widget.containers.snapshots,
                  builder: (context, snapshot) {
                    final runningCount = (snapshot.data ?? const [])
                        .where((c) => c.state == ContainerState.running)
                        .length;
                    return ListView(
                      children: [
                        const SidebarSection(title: '工作'),
                        _sidebarItem(0, badge: runningCount),
                        _sidebarItem(1),
                        _sidebarItem(2),
                        const SidebarSection(title: '资源'),
                        _sidebarItem(3),
                        _sidebarItem(4),
                        _sidebarItem(5),
                        const SidebarSection(title: '系统'),
                        _sidebarItem(6),
                        _sidebarItem(7),
                        _sidebarItem(8),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.readiness,
              builder: (context, _) {
                return Column(
                  children: [
                    if (_showDegradedBanner)
                      _DegradedBanner(
                        controller: widget.readiness,
                        onOpenRuntime: () => setState(
                          () => _selected = kSidebarItems.indexOf('运行时'),
                        ),
                      ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: GcmMotion.pageSwitchDuration,
                        switchInCurve: GcmMotion.pageSwitchCurve,
                        switchOutCurve: GcmMotion.pageSwitchCurve,
                        child: KeyedSubtree(
                          key: ValueKey(kSidebarItems[_selected]),
                          child: _page(context),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  bool get _showDegradedBanner {
    final level = widget.readiness.readiness?.level;
    return level == ReadinessLevel.serviceNotRunning ||
        level == ReadinessLevel.kernelMissing;
  }

  Widget _page(BuildContext context) {
    final title = kSidebarItems[_selected];
    switch (title) {
      case '容器':
        return ContainersPage(
          service: widget.containers,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
      case 'Compose 项目':
        return ComposePage(
          service: widget.compose,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
      case '镜像':
        return ImagesPage(
          service: widget.images,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
      case '挂载':
        return MountsPage(
          service: widget.mounts,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
      case '网络':
        return NetworksPage(
          service: widget.networks,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
      case '项目':
        return ProjectsPage(
          service: widget.projects,
          containerService: widget.containers,
          imageService: widget.images,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
      case '运行时':
        return RuntimePage(controller: widget.readiness);
      case '设置':
      case 'MCP': // MCP 是设置页内的区块（ui-ia.md D9）
        return SettingsPage(
          mcp: widget.mcp,
          menuBar: widget.menuBar,
          readiness: widget.readiness,
        );
      default:
        return PlaceholderSectionPage(
          title: title,
          controller: widget.readiness,
          onOpenRuntime: () =>
              setState(() => _selected = kSidebarItems.indexOf('运行时')),
        );
    }
  }
}

/// 降级壳横幅：服务未运行 / 内核缺失时的一键修复入口（方案 C 非阻塞侧）。
class _DegradedBanner extends StatelessWidget {
  const _DegradedBanner({
    required this.controller,
    required this.onOpenRuntime,
  });

  final ReadinessController controller;
  final VoidCallback onOpenRuntime;

  @override
  Widget build(BuildContext context) {
    final level = controller.readiness!.level;
    final kernelMissing = level == ReadinessLevel.kernelMissing;
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_outlined,
              size: 16,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                kernelMissing ? '运行时缺少默认内核，容器无法启动' : '运行时未启动',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            TextButton(onPressed: onOpenRuntime, child: const Text('打开引导检查')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: controller.busy
                  ? null
                  : () => unawaited(
                      kernelMissing
                          ? controller.installKernel()
                          : controller.startRuntime(),
                    ),
              child: Text(
                controller.busy
                    ? '正在处理…'
                    : (kernelMissing ? '安装推荐内核' : '启动运行时'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
