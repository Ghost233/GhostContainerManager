/// Decoding of raw container log byte streams (T2a).
///
/// The bridge emits [BridgeLogEvent] chunks from the two XPC log
/// FileHandles (stdio + boot). UTF-8 sequences may span chunk boundaries,
/// so decoding must be chunked; this module binds that decoding to typed
/// [ContainerLogEvent]s for the UI layer. MCP deliberately has no logs
/// tool (#13 decision — logs are a UI surface).
library;

import 'dart:convert';

import '../bridge/container_bridge.dart';

/// One decoded log event for the UI.
class ContainerLogEvent {
  const ContainerLogEvent.data({required this.source, required this.text})
    : kind = 'data',
      message = null;

  const ContainerLogEvent.eof()
    : kind = 'eof',
      source = '',
      text = '',
      message = null;

  const ContainerLogEvent.error(this.message)
    : kind = 'error',
      source = '',
      text = '';

  /// 'data' | 'eof' | 'error'.
  final String kind;

  /// 'stdio' | 'boot' (data events only).
  final String source;

  /// Decoded text chunk (data events only).
  final String text;

  /// Failure description (error events only).
  final String? message;
}

/// Binds chunked UTF-8 decoding onto a raw bridge log stream.
Stream<ContainerLogEvent> decodeContainerLogs(
  Stream<BridgeLogEvent> source,
) async* {
  final buffers = <String, StringBuffer>{};
  final sinks = <String, Sink<List<int>>>{};

  StringBuffer bufferFor(String sourceName) {
    final existing = buffers[sourceName];
    if (existing != null) return existing;
    final buffer = StringBuffer();
    buffers[sourceName] = buffer;
    // allowMalformed: an unfinished sequence at end-of-stream must flush as
    // U+FFFD on close instead of throwing FormatException (matches the
    // Swift side's lossy decoding).
    sinks[sourceName] = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(buffer));
    return buffer;
  }

  await for (final event in source) {
    switch (event.event) {
      case 'data':
        final buffer = bufferFor(event.source);
        sinks[event.source]!.add(event.bytes);
        if (buffer.isNotEmpty) {
          yield ContainerLogEvent.data(
            source: event.source,
            text: buffer.toString(),
          );
          buffer.clear();
        }
      case 'error':
        yield ContainerLogEvent.error(event.message ?? 'log stream error');
      case 'eof':
        // Closing the chunked sinks flushes any tail fragment (an
        // incomplete UTF-8 sequence at end-of-stream decodes to a
        // replacement char) into the buffers; those tails belong to the
        // log and must be emitted before the eof marker.
        for (final MapEntry(:key, :value) in sinks.entries) {
          value.close();
          final tail = buffers[key]!.toString();
          if (tail.isNotEmpty) {
            yield ContainerLogEvent.data(source: key, text: tail);
            buffers[key]!.clear();
          }
        }
        yield const ContainerLogEvent.eof();
    }
  }
}
