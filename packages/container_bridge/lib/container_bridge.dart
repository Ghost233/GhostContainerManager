/// Native bridge plugin for Apple container operations.
///
/// This package carries the Swift implementation (ContainerAPIClient over
/// XPC + a CLI process wrapper) and the Dart channel wrapper used by the
/// app's `lib/bridge/method_channel_container_bridge.dart`. The abstract
/// seam (`ContainerBridge`) lives in the app's `lib/bridge/`.
/// See docs/spec/architecture.md §2/§3.
library;

import 'package:flutter/services.dart';

/// Channel names shared with the Swift side
/// (`macos/container_bridge/Sources/container_bridge/ContainerBridgePlugin.swift`).
abstract final class ContainerBridgeChannels {
  /// Method channel for request/response operations.
  static const String methods = 'com.ghost233.container_bridge/methods';

  /// Event channel for streams (logs, pull progress, stats).
  static const String events = 'com.ghost233.container_bridge/events';
}

/// Method names accepted by the Swift handler (T1a: system domain,
/// T2a: container read domain).
abstract final class ContainerBridgeMethods {
  static const String systemVersion = 'system.version';
  static const String systemStatus = 'system.status';
  static const String systemStart = 'system.start';
  static const String systemStop = 'system.stop';
  static const String systemKernelSet = 'system.kernelSet';
  static const String systemPing = 'system.ping';
  static const String containerList = 'container.list';
  static const String containerGet = 'container.get';
  static const String containerStats = 'container.stats';
}

/// Stream selectors understood by the event channel (`onListen` arguments).
abstract final class ContainerBridgeStreams {
  /// `container.logs` — XPC log FileHandles (stdio + boot) for one
  /// container; arguments: `{'stream': 'container.logs', 'id': ...}`.
  static const String containerLogs = 'container.logs';
}

/// Typed wrapper over the method channel. Returns raw
/// `Map<String, Object?>` payloads; mapping to bridge result types happens
/// in the app's adapter (keeps this package free of app types).
class ContainerBridgeChannel {
  ContainerBridgeChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ContainerBridgeChannels.methods);

  final MethodChannel _channel;

  Future<Map<String, Object?>> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      method,
      arguments,
    );
    if (result == null) {
      throw PlatformException(
        code: 'nullResult',
        message: 'bridge returned null for $method',
      );
    }
    return result;
  }

  /// `container system version --format json`.
  Future<Map<String, Object?>> systemVersion() =>
      _invoke(ContainerBridgeMethods.systemVersion);

  /// `container system status --format json`.
  Future<Map<String, Object?>> systemStatus() =>
      _invoke(ContainerBridgeMethods.systemStatus);

  /// `container system start` with explicit kernel-install flag.
  Future<Map<String, Object?>> systemStart({required bool installKernel}) =>
      _invoke(ContainerBridgeMethods.systemStart, <String, Object?>{
        'installKernel': installKernel,
      });

  /// `container system stop`.
  Future<Map<String, Object?>> systemStop() =>
      _invoke(ContainerBridgeMethods.systemStop);

  /// `container system kernel set --recommended` (+ `--force`).
  Future<Map<String, Object?>> systemKernelSet({bool force = false}) =>
      _invoke(ContainerBridgeMethods.systemKernelSet, <String, Object?>{
        'force': force,
      });

  /// XPC health-check ping (`ClientHealthCheck.ping()`).
  Future<Map<String, Object?>> systemPing() =>
      _invoke(ContainerBridgeMethods.systemPing);

  /// `ContainerClient.list()` — unfiltered snapshot dictionaries.
  Future<List<Map<String, Object?>>> containerList() async {
    final result = await _channel.invokeListMethod<Object?>(
      ContainerBridgeMethods.containerList,
    );
    return (result ?? const [])
        .map((entry) => (entry! as Map).cast<String, Object?>())
        .toList(growable: false);
  }

  /// `ContainerClient.get(id:)` — full snapshot incl. configuration.
  Future<Map<String, Object?>> containerGet(String id) =>
      _invoke(ContainerBridgeMethods.containerGet, <String, Object?>{
        'id': id,
      });

  /// `ContainerClient.stats(id:)` — single snapshot (fails for stopped
  /// containers; classification is the Service layer's job).
  Future<Map<String, Object?>> containerStats(String id) =>
      _invoke(ContainerBridgeMethods.containerStats, <String, Object?>{
        'id': id,
      });
}

/// Typed wrapper over the event channel (log streams, pull progress, …).
class ContainerBridgeEvents {
  ContainerBridgeEvents({EventChannel? channel})
    : _channel =
          channel ?? const EventChannel(ContainerBridgeChannels.events);

  final EventChannel _channel;

  /// Raw `container.logs` event maps for [id]:
  /// data events carry `source` ('stdio'/'boot') and `data` (Uint8List);
  /// terminal events carry `event` ('eof'/'error', plus `message`).
  Stream<Map<String, Object?>> containerLogs(String id) {
    return _channel
        .receiveBroadcastStream(<String, Object?>{
          'stream': ContainerBridgeStreams.containerLogs,
          'id': id,
        })
        .map((event) => (event as Map).cast<String, Object?>());
  }
}
