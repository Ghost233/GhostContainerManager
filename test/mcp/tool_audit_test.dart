import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/mcp/tool_audit.dart';

void main() {
  group('McpToolAuditor', () {
    test('keeps newest-first records and enforces capacity', () {
      final auditor = McpToolAuditor(capacity: 3);
      final base = DateTime.utc(2026, 1, 1);

      for (var i = 0; i < 5; i++) {
        auditor.record(
          tool: 'tool_$i',
          startedAt: base.add(Duration(seconds: i)),
          succeeded: i.isEven,
          duration: Duration(milliseconds: 10 + i),
        );
      }

      expect(auditor.records, hasLength(3));
      expect(auditor.records.map((r) => r.tool), [
        'tool_4',
        'tool_3',
        'tool_2',
      ]);
      expect(auditor.records.first.succeeded, isTrue);
      expect(auditor.records.first.duration, const Duration(milliseconds: 14));
    });

    test('recordCall uses the injected clock', () {
      final when = DateTime.utc(2026, 2, 3, 4, 5, 6);
      final auditor = McpToolAuditor(clock: () => when);

      auditor.recordCall(
        tool: 'system_status',
        succeeded: true,
        duration: const Duration(milliseconds: 7),
      );

      expect(auditor.records.single.startedAt, when);
    });

    test('emits a change event after each recorded call', () async {
      final auditor = McpToolAuditor();
      var events = 0;
      final sub = auditor.changes.listen((_) => events++);

      auditor.recordCall(tool: 'a', succeeded: true, duration: Duration.zero);
      auditor.recordCall(
        tool: 'b',
        succeeded: false,
        duration: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, 2);
      await sub.cancel();
      await auditor.dispose();
    });
  });
}
