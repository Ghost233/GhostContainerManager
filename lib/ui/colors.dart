/// 语义色 tokens（docs/design.md §2）。页面禁止直接写 Color(0x...)/Colors.x，
/// 一律经 GcmColors 取用，保证运行/停止/合成/失败/未知一致呈现。
library;

import 'package:flutter/material.dart';

/// 容器/镜像/项目状态与操作的语义色。
abstract final class GcmColors {
  /// 运行中（systemGreen 系，浅色）。
  static const Color stateRunning = Color(0xFF1D7A34);

  /// 合成/过渡态：starting/stopping/deleting（systemYellow 系）。
  static const Color stateTransition = Color(0xFF8A6D00);

  /// 成功（构建成功、操作完成）。
  static const Color success = Color(0xFF1D7A34);

  /// 停止/未知：走次级文本灰，由 context 解析（随深浅色与对比度设置）。
  static Color stateStopped(BuildContext context) =>
      Theme.of(context).colorScheme.outline;

  /// 失败/错误：走 colorScheme 错误语义。
  static Color stateFailed(BuildContext context) =>
      Theme.of(context).colorScheme.error;

  /// 破坏性操作（删除/回收）按钮色。
  static Color destructive(BuildContext context) =>
      Theme.of(context).colorScheme.error;

  /// 辅助信息/label/时间的次级文本色。
  static Color textSecondary(BuildContext context) =>
      Theme.of(context).colorScheme.outline;

  /// 卡片/详情面板背景（内容层材质）。
  static Color surfaceCard(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerLowest;

  /// 侧栏背景（导航层材质）。
  static Color surfaceSidebar(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerLow;

  /// 状态字符串 → 语义色。运行/合成/失败为固定色，其余（停止/未知）走 outline。
  /// 需要 context 的状态色请用 [stateColorOf]。
  static Color stateColor(String state) {
    return switch (state) {
      'running' || 'started' || 'ready' => stateRunning,
      'starting' || 'stopping' || 'deleting' || 'restarting' => stateTransition,
      // 失败色需 context；此处返回固定警示色仅供无 context 的映射测试。
      'failed' || 'error' => const Color(0xFFC62828),
      _ => const Color(0xFF6E6E73), // stopped/unknown 中性灰占位
    };
  }

  /// 状态字符串 → 语义色（context 解析版，页面应优先用此）。
  static Color stateColorOf(BuildContext context, String state) {
    return switch (state) {
      'running' || 'started' || 'ready' => stateRunning,
      'starting' || 'stopping' || 'deleting' || 'restarting' => stateTransition,
      'failed' || 'error' => stateFailed(context),
      _ => stateStopped(context),
    };
  }
}
