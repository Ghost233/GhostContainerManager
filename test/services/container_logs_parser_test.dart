/// Unit tests for decodeContainerLogs (review round: UTF-8 chunk-boundary
/// safety and eof tail flushing per source).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/services/container_logs_parser.dart';

void main() {
  group('decodeContainerLogs', () {
    test('decodes multi-byte UTF-8 split across chunk boundaries', () async {
      // 'héllo': é is 0xC3 0xA9; split inside the sequence.
      final bytes = utf8.encode('héllo');
      final events = await decodeContainerLogs(
        Stream<BridgeLogEvent>.fromIterable([
          BridgeLogEvent.data(
            source: 'stdio',
            bytes: Uint8List.fromList(bytes.sublist(0, 2)), // 'h' + 0xC3
          ),
          BridgeLogEvent.data(
            source: 'stdio',
            bytes: Uint8List.fromList(bytes.sublist(2)), // 0xA9 + 'llo'
          ),
          const BridgeLogEvent.eof(),
        ]),
      ).toList();

      final dataText = events
          .where((e) => e.kind == 'data')
          .map((e) => e.text)
          .join();
      expect(dataText, 'héllo');
      expect(events.last.kind, 'eof');
    });

    test('keeps per-source buffers independent across chunks', () async {
      final events = await decodeContainerLogs(
        Stream<BridgeLogEvent>.fromIterable([
          BridgeLogEvent.data(
            source: 'stdio',
            bytes: Uint8List.fromList(utf8.encode('out-1 ')),
          ),
          BridgeLogEvent.data(
            source: 'boot',
            bytes: Uint8List.fromList(utf8.encode('boot-1 ')),
          ),
          BridgeLogEvent.data(
            source: 'stdio',
            bytes: Uint8List.fromList(utf8.encode('out-2')),
          ),
          const BridgeLogEvent.eof(),
        ]),
      ).toList();

      final bySource = <String, String>{};
      for (final e in events.where((e) => e.kind == 'data')) {
        bySource[e.source] = (bySource[e.source] ?? '') + e.text;
      }
      expect(bySource['stdio'], 'out-1 out-2');
      expect(bySource['boot'], 'boot-1 ');
      expect(events.last.kind, 'eof');
    });

    test('eof flushes each source buffer tail before the eof event', () async {
      // 'ok' + the leading byte of a 3-byte sequence (0xE4). The decoder
      // buffers the incomplete tail; only sink.close() on eof flushes it
      // (as U+FFFD). It must be emitted as a data event before eof.
      final incomplete = Uint8List.fromList([0x6F, 0x6B, 0xE4]); // 'ok' + ␣
      final events = await decodeContainerLogs(
        Stream<BridgeLogEvent>.fromIterable([
          BridgeLogEvent.data(source: 'boot', bytes: incomplete),
          const BridgeLogEvent.eof(),
        ]),
      ).toList();

      expect(events, hasLength(3));
      expect(events[0].kind, 'data');
      expect(events[0].source, 'boot');
      expect(events[0].text, 'ok');
      expect(events[1].kind, 'data');
      expect(events[1].source, 'boot');
      expect(events[1].text, '\uFFFD');
      expect(events[2].kind, 'eof');
    });

    test('error events pass through untouched', () async {
      final events = await decodeContainerLogs(
        Stream<BridgeLogEvent>.fromIterable([
          const BridgeLogEvent.error('xpc dropped'),
        ]),
      ).toList();
      expect(events.single.kind, 'error');
      expect(events.single.message, 'xpc dropped');
    });
  });
}
