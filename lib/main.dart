import 'package:flutter/material.dart';

void main() {
  runApp(const GhostContainerManagerApp());
}

/// P0 scaffold: minimal three-column workspace shell.
/// Real UI lands in P3; navigation follows docs/spec/ui-ia.md (D1, 方案 A).
class GhostContainerManagerApp extends StatelessWidget {
  const GhostContainerManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostContainerManager',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const WorkspacePlaceholder(),
    );
  }
}

/// Sidebar entries per docs/spec/ui-ia.md (#13 回填后的 9 项).
const List<String> _sidebarItems = <String>[
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

class WorkspacePlaceholder extends StatelessWidget {
  const WorkspacePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          // 侧栏（视觉基线 224，macos-ui-standards）
          SizedBox(
            width: 224,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: ListView(
                children: <Widget>[
                  for (final String item in _sidebarItems)
                    ListTile(title: Text(item), dense: true),
                ],
              ),
            ),
          ),
          // 列表列（空态占位）
          const Expanded(
            flex: 2,
            child: Center(child: Text('暂无内容', textAlign: TextAlign.center)),
          ),
          const VerticalDivider(width: 1),
          // 检查器列（空态占位）
          const Expanded(
            child: Center(child: Text('未选择项目', textAlign: TextAlign.center)),
          ),
        ],
      ),
    );
  }
}
