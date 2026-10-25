/// 设置页：通用偏好与内置 MCP 服务。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/menu_bar_controller.dart';
import '../../mcp/tool_audit.dart';
import '../../services/app_constants.dart';
import '../../ui/colors.dart';
import '../../ui/components.dart';
import '../../ui/text.dart';
import 'mcp_settings_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.mcp, required this.menuBar});

  final McpSettingsController mcp;
  final MenuBarController menuBar;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mcp,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            _GeneralSection(menuBar: menuBar),
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

class _GeneralSection extends StatelessWidget {
  const _GeneralSection({required this.menuBar});

  final MenuBarController menuBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: '通用',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '外观',
            style: theme.textTheme.bodySmall?.copyWith(
              color: GcmColors.textSecondary(context),
            ),
          ),
          ListenableBuilder(
            listenable: menuBar,
            builder: (context, _) => Column(
              children: [
                SwitchListTile(
                  key: const Key('settings-menu-bar-visible'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示菜单栏图标'),
                  subtitle: const Text('在 macOS 菜单栏显示运行状态和快捷操作'),
                  value: menuBar.visible,
                  onChanged: (value) => unawaited(menuBar.setVisible(value)),
                ),
                if (menuBar.lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '菜单栏操作失败：${menuBar.lastError}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: GcmColors.stateFailed(context),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '行为',
            style: theme.textTheme.bodySmall?.copyWith(
              color: GcmColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: menuBar,
            builder: (context, _) => DropdownButtonFormField<String>(
              key: const Key('settings-default-start-page'),
              initialValue: menuBar.defaultStartPage,
              decoration: const InputDecoration(
                labelText: '默认启动页',
                helperText: '下次启动主窗口时显示',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: kDefaultStartPages
                  .map(
                    (page) => DropdownMenuItem<String>(
                      value: page,
                      child: Text(page),
                    ),
                  )
                  .toList(),
              onChanged: (page) {
                if (page != null) {
                  unawaited(menuBar.setDefaultStartPage(page));
                }
              },
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: const Key('settings-language'),
            initialValue: 'zh',
            decoration: const InputDecoration(
              labelText: '语言',
              helperText: 'v1 仅支持中文',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem<String>(value: 'zh', child: Text('中文')),
            ],
            onChanged: null,
          ),
        ],
      ),
    );
  }
}

class _McpSection extends StatelessWidget {
  const _McpSection({required this.mcp});

  final McpSettingsController mcp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          title: 'MCP 服务',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                    color: GcmColors.stateFailed(context),
                  ),
                ),
              ],
              if (mcp.running) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: CopyValue(value: mcp.endpoint),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: '最近调用',
          child: mcp.recentCalls.isEmpty
              ? Text('暂无 MCP 调用记录', style: theme.textTheme.bodySmall)
              : _RecentCallsList(records: mcp.recentCalls),
        ),
      ],
    );
  }
}

/// 最近 MCP 调用简表（issue #16）：工具名、时间、成败与耗时。
/// 数据来自 [McpToolAuditor]，有界（默认 20 条），不记录参数与结果。
class _RecentCallsList extends StatelessWidget {
  const _RecentCallsList({required this.records});

  final List<McpCallRecord> records;

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = monoTextStyle(context)
        ?.copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final record in records)
          SizedBox(
            height: 32,
            child: Row(
              children: [
                Icon(
                  record.succeeded
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  size: 14,
                  color: record.succeeded
                      ? GcmColors.success
                      : GcmColors.stateFailed(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.tool,
                    style: mono,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_two(record.startedAt.hour)}:'
                  '${_two(record.startedAt.minute)}:'
                  '${_two(record.startedAt.second)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Text(
                  '${record.duration.inMilliseconds}ms',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: GcmColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
      ],
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
    return SectionCard(
      title: '关于',
      child: Text(
        '$applicationDisplayName '
        '${gcmAppVersion == 'dev' ? '开发版' : gcmAppVersion}',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
