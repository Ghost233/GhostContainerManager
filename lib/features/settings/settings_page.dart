/// 设置页（T1b 范围：MCP 区块，issue #16 验收 4；ui-ia.md D9）。
/// 其余区块（通用 / Container 路径 / 菜单栏）由后续任务补齐。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mcp_settings_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.mcp});

  final McpSettingsController mcp;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mcp,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('设置', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            _McpSection(mcp: mcp),
            const SizedBox(height: 24),
            const _AboutSection(),
          ],
        );
      },
    );
  }
}

class _McpSection extends StatelessWidget {
  const _McpSection({required this.mcp});

  final McpSettingsController mcp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MCP 服务', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用内置 MCP server'),
              subtitle: const Text('HTTP（仅 127.0.0.1）+ stdio 瘦代理'),
              value: mcp.enabled,
              onChanged: mcp.setEnabled,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(width: 160, child: _PortField(mcp: mcp)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    mcp.running
                        ? '运行中：${mcp.endpoint}'
                        : (mcp.enabled ? '未运行' : '已停用'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (mcp.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                mcp.lastError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (mcp.running) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      mcp.endpoint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制连接地址',
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: mcp.endpoint),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制连接地址')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text('最近调用', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              mcp.recentCalls.isEmpty ? '暂无 MCP 调用记录' : '',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PortField extends StatefulWidget {
  const _PortField({required this.mcp});

  final McpSettingsController mcp;

  @override
  State<_PortField> createState() => _PortFieldState();
}

class _PortFieldState extends State<_PortField> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.mcp.port}',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: const InputDecoration(labelText: '端口', isDense: true),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      controller: _controller,
      enabled: widget.mcp.enabled,
      onSubmitted: (raw) {
        final value = int.tryParse(raw);
        if (value != null && value > 0 && value <= 65535) {
          widget.mcp.setPort(value);
        } else {
          _controller.text = '${widget.mcp.port}'; // 非法输入回退
        }
      },
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关于', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              'GhostContainerManager 0.0.0（开发中）',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
