/// 字体与格式化 helper（docs/design.md §4）。标识值用等宽字体；
/// 从 features/containers/containers_page.dart 上移，全页面统一引用。
library;

import 'package:flutter/material.dart';

/// 系统等宽字体（标识值：容器 id、镜像引用、路径、label、日志），中文回退保留。
TextStyle? monoTextStyle(BuildContext context) {
  return Theme.of(context).textTheme.bodySmall?.copyWith(
    fontFamily: 'Menlo',
    fontFamilyFallback: const ['SF Mono', 'monospace'],
  );
}

/// 字节数人性化（B/KB/MB/GB/TB）。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024.0;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 时长人性化（如 1m 5s / 2h 3m）。
String formatDuration(Duration duration) {
  if (duration.inDays > 0) {
    return '${duration.inDays}d ${duration.inHours % 24}h';
  }
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes % 60}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  }
  return '${duration.inSeconds}s';
}

/// 相对时间（如 3 分钟前 / 2 小时前）；未来或异常回退绝对日期。
String formatRelative(DateTime value, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(value);
  if (diff.isNegative) return formatDateTime(value);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return formatDateTime(value);
}

/// 绝对日期时间（yyyy-MM-dd HH:mm）。
String formatDateTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
