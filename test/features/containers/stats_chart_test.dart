import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/features/containers/stats_chart.dart';
import 'package:ghost_container_manager/services/container_models.dart';

void main() {
  test('图表点使用样本时间戳而不是样本序号', () {
    final first = DateTime.utc(2026, 1, 1, 12);
    final second = first.add(const Duration(seconds: 2));
    final samples = [
      ContainerStatsSample(timestamp: first, cpuPercent: 12.5),
      ContainerStatsSample(timestamp: second, cpuPercent: 13.5),
    ];

    final spots = statsChartSpots(samples, (sample) => sample.cpuPercent);

    expect(spots.map((spot) => spot.x), [
      first.millisecondsSinceEpoch,
      second.millisecondsSinceEpoch,
    ]);
    expect(spots.map((spot) => spot.y), [12.5, 13.5]);
  });

  test('时间窗保留 cutoff 到当前时刻的样本并排除未来样本', () {
    final now = DateTime.utc(2026, 1, 1, 12, 15);
    final cutoff = now.subtract(const Duration(minutes: 5));
    final recent = now.subtract(const Duration(seconds: 2));
    final samples = [
      ContainerStatsSample(
        timestamp: cutoff.subtract(const Duration(milliseconds: 1)),
      ),
      ContainerStatsSample(timestamp: cutoff),
      ContainerStatsSample(timestamp: recent),
      ContainerStatsSample(timestamp: now.add(const Duration(milliseconds: 1))),
    ];

    final visible = statsSamplesInWindow(
      samples,
      now: now,
      window: const Duration(minutes: 5),
    );

    expect(visible.map((sample) => sample.timestamp), [cutoff, recent]);
  });

  test('超过三个采样周期的空段拆线，六秒间隔仍连续', () {
    final first = DateTime.utc(2026, 1, 1, 12);
    final times = [
      first,
      first.add(const Duration(seconds: 2)),
      first.add(const Duration(seconds: 8)),
      first.add(const Duration(seconds: 16)),
      first.add(const Duration(seconds: 18)),
    ];
    final samples = [
      for (var index = 0; index < times.length; index++)
        ContainerStatsSample(
          timestamp: times[index],
          cpuPercent: index.toDouble(),
        ),
    ];

    final segments = splitStatsChartSpots(
      statsChartSpots(samples, (sample) => sample.cpuPercent),
    );

    expect(segments.map((segment) => segment.length), [3, 2]);
    expect(segments[0].last.x, times[2].millisecondsSinceEpoch);
    expect(segments[1].first.x, times[3].millisecondsSinceEpoch);
  });
}
