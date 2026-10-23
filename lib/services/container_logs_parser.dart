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
    sinks[sourceName] = const Utf8Decoder().startChunkedConversion(
      StringConversionSink.fromStringSink(buffer),
    );
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
        for (final sink in sinks.values) {
          sink.close();
        }
        yield const ContainerLogEvent.eof();
    }
  }
}
