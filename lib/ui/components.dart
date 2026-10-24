/// lib/ui/ 共享组件（docs/design.md §5）。API 小而稳，P1 详情页重做复用。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'colors.dart';
import 'text.dart';

/// 语义卡片：标题 + 内容区 + 可选操作行。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  final String title;
  final Widget child;

  /// 标题行右侧的操作按钮（可选）。
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: GcmColors.surfaceCard(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                ...?actions,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

/// 标识值 + 悬浮 Copy 按钮 + 复制反馈。等宽字体，长值省略后可复制全文。
class CopyValue extends StatelessWidget {
  const CopyValue({super.key, required this.value, this.display});

  /// 复制到剪贴板的完整值。
  final String value;

  /// 显示文本（省略/截断版）；缺省显示 [value]。
  final String? display;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            display ?? value,
            style: monoTextStyle(context),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        InkWell(
          key: Key('copy-value-$value'),
          onTap: () => _copy(context),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              Icons.copy,
              size: 14,
              color: GcmColors.textSecondary(context),
            ),
          ),
        ),
      ],
    );
  }
}

/// 敏感值（环境变量等）默认打码 ⦿⦿⦿ + Show/Copy 切换。
class MaskedValue extends StatefulWidget {
  const MaskedValue({super.key, required this.value});

  final String value;

  @override
  State<MaskedValue> createState() => _MaskedValueState();
}

class _MaskedValueState extends State<MaskedValue> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            _shown ? widget.value : '⦿⦿⦿⦿⦿⦿',
            style: monoTextStyle(context),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        InkWell(
          key: Key('masked-toggle-${widget.value}'),
          onTap: () => setState(() => _shown = !_shown),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              _shown ? Icons.visibility_off : Icons.visibility,
              size: 14,
              color: GcmColors.textSecondary(context),
            ),
          ),
        ),
      ],
    );
  }
}

/// 状态点：语义色圆点（配文字标签使用，不单独传达状态）。
class StateDot extends StatelessWidget {
  const StateDot({super.key, required this.state, this.size = 10});

  /// 状态字符串（running/stopping/failed/…），经 GcmColors 映射。
  final String state;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('state-dot'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: GcmColors.stateColorOf(context, state),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 侧栏分组标题（工作/资源/系统）。
class SidebarSection extends StatelessWidget {
  const SidebarSection({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: GcmColors.textSecondary(context),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 侧栏计数徽章（如容器运行中数）。
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.tone});

  final int count;

  /// 徽章底色；缺省用强调色容器。
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = tone ?? theme.colorScheme.secondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
