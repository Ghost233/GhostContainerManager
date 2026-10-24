import 'package:fl_chart/fl_chart.dart';

import '../../services/container_models.dart';

/// 将统计样本转换为以 Unix 毫秒为 x 轴的图表点。
List<FlSpot> statsChartSpots(
  Iterable<ContainerStatsSample> samples,
  double? Function(ContainerStatsSample sample) value,
) {
  final spots = <FlSpot>[];
  for (final sample in samples) {
    final y = value(sample);
    if (y == null) continue;
    spots.add(FlSpot(sample.timestamp.millisecondsSinceEpoch.toDouble(), y));
  }
  return spots;
}

/// 返回 `[now - window, now]` 内的样本，保持原有时间顺序。
List<ContainerStatsSample> statsSamplesInWindow(
  Iterable<ContainerStatsSample> samples, {
  required DateTime now,
  required Duration window,
}) {
  final cutoff = now.subtract(window);
  return samples
      .where(
        (sample) =>
            !sample.timestamp.isBefore(cutoff) &&
            !sample.timestamp.isAfter(now),
      )
      .toList(growable: false);
}

/// 将超过三个默认 2 秒采样周期的空段拆成独立折线。
List<List<FlSpot>> splitStatsChartSpots(
  List<FlSpot> spots, {
  Duration maxGap = const Duration(seconds: 6),
}) {
  if (spots.isEmpty) return const [];
  final segments = <List<FlSpot>>[];
  var current = <FlSpot>[spots.first];
  for (final spot in spots.skip(1)) {
    final gap = spot.x - current.last.x;
    if (gap > maxGap.inMilliseconds) {
      segments.add(current);
      current = <FlSpot>[];
    }
    current.add(spot);
  }
  segments.add(current);
  return segments;
}
