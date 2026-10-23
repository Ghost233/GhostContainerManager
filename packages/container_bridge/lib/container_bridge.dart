/// Native bridge plugin for Apple container operations.
///
/// This package carries the Swift implementation (ContainerAPIClient over
/// XPC for system/container/image work, plus the CLI process wrapper used by
/// network and compose operations) and the Dart channel wrapper used by the
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
  static const String containerCreate = 'container.create';
  static const String containerStart = 'container.start';
  static const String containerStop = 'container.stop';
  static const String containerDelete = 'container.delete';
  static const String containerKill = 'container.kill';
  static const String networkList = 'network.list';
  static const String networkInspect = 'network.inspect';
  static const String composeHelp = 'compose.help';
  static const String composeRun = 'compose.run';
  static const String imageList = 'image.list';
  static const String imageInspect = 'image.inspect';
  static const String imageDelete = 'image.delete';
  static const String imagePull = 'image.pull';
  static const String imagePullCancel = 'image.pullCancel';
}

/// Stream selectors understood by the event channel (`onListen` arguments).
abstract final class ContainerBridgeStreams {
  /// `container.logs` — XPC log FileHandles (stdio + boot) for one
  /// container; arguments: `{'stream': 'container.logs', 'id': ...}`.
  static const String containerLogs = 'container.logs';

  /// `image.pull` — throttled (~10 Hz) pull progress for ALL pulls;
  /// consumers filter by the `pullId` payload field.
  /// Arguments: `{'stream': 'image.pull'}`.
  static const String imagePull = 'image.pull';
}

/// Typed wrapper over the method channel. Returns raw
/// `Map<String, Object?>` payloads; mapping to bridge result types happens
/// in the app's adapter (keeps this package free of app types).
class ContainerBridgeChannel {
  ContainerBridgeChannel({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(ContainerBridgeChannels.methods);

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
  Future<Map<String, Object?>> systemKernelSet({bool force = false}) => _invoke(
    ContainerBridgeMethods.systemKernelSet,
    <String, Object?>{'force': force},
  );

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
      _invoke(ContainerBridgeMethods.containerGet, <String, Object?>{'id': id});

  /// `ContainerClient.stats(id:)` — single snapshot (fails for stopped
  /// containers; classification is the Service layer's job).
  Future<Map<String, Object?>> containerStats(String id) => _invoke(
    ContainerBridgeMethods.containerStats,
    <String, Object?>{'id': id},
  );

  /// `ContainerClient.create` with an existing local image.
  Future<Map<String, Object?>> containerCreate({
    required String id,
    required String image,
    List<String> command = const [],
    List<String> env = const [],
    List<String> ports = const [],
    String? network,
  }) => _invoke(ContainerBridgeMethods.containerCreate, <String, Object?>{
    'id': id,
    'image': image,
    'command': command,
    'env': env,
    'ports': ports,
    'network': ?network,
  });

  /// `ContainerClient.bootstrap` + process start (idempotent upstream).
  Future<Map<String, Object?>> containerStart(String id) => _invoke(
    ContainerBridgeMethods.containerStart,
    <String, Object?>{'id': id},
  );

  /// Stop with [timeoutSeconds] of grace (default five), then SIGKILL.
  Future<Map<String, Object?>> containerStop(
    String id, {
    int timeoutSeconds = 5,
  }) => _invoke(ContainerBridgeMethods.containerStop, <String, Object?>{
    'id': id,
    'timeoutSeconds': timeoutSeconds,
  });

  /// Delete; [force] is required for a running container.
  Future<Map<String, Object?>> containerDelete(
    String id, {
    bool force = false,
  }) => _invoke(ContainerBridgeMethods.containerDelete, <String, Object?>{
    'id': id,
    'force': force,
  });

  /// Send [signal] to the container's init process.
  Future<Map<String, Object?>> containerKill(
    String id, {
    String signal = 'KILL',
  }) => _invoke(ContainerBridgeMethods.containerKill, <String, Object?>{
    'id': id,
    'signal': signal,
  });

  /// `container network ls --format json`.
  Future<Map<String, Object?>> networkList() =>
      _invoke(ContainerBridgeMethods.networkList);

  /// `container network inspect <id>`.
  Future<Map<String, Object?>> networkInspect(String id) => _invoke(
    ContainerBridgeMethods.networkInspect,
    <String, Object?>{'id': id},
  );

  /// `container compose --help` (plugin-presence probe).
  Future<Map<String, Object?>> composeHelp() =>
      _invoke(ContainerBridgeMethods.composeHelp);

  /// `container compose <arguments>`; [timeoutSeconds] maps to the native
  /// CLI runner timeout (default 600 on the Swift side).
  Future<Map<String, Object?>> composeRun(
    List<String> arguments, {
    int? timeoutSeconds,
  }) => _invoke(ContainerBridgeMethods.composeRun, <String, Object?>{
    'arguments': arguments,
    'timeoutSeconds': ?timeoutSeconds,
  });

  /// `ClientImage.list()` — unfiltered ImageDescription dictionaries.
  Future<List<Map<String, Object?>>> imageList() async {
    final result = await _channel.invokeListMethod<Object?>(
      ContainerBridgeMethods.imageList,
    );
    return (result ?? const [])
        .map((entry) => (entry! as Map).cast<String, Object?>())
        .toList(growable: false);
  }

  /// `ClientImage.get()` + index/manifest/config rebuild.
  Future<Map<String, Object?>> imageInspect(String reference) => _invoke(
    ContainerBridgeMethods.imageInspect,
    <String, Object?>{'reference': reference},
  );

  /// `ClientImage.delete(reference:, garbageCollect: false)`.
  Future<Map<String, Object?>> imageDelete(String reference) => _invoke(
    ContainerBridgeMethods.imageDelete,
    <String, Object?>{'reference': reference},
  );

  /// `ClientImage.pull(...)`; progress flows on the `image.pull` event
  /// stream tagged with [pullId]. Resolves with the pulled description or
  /// `{reference, cancelled: true}` after [imagePullCancel].
  Future<Map<String, Object?>> imagePull({
    required String pullId,
    required String reference,
    String? platform,
  }) => _invoke(ContainerBridgeMethods.imagePull, <String, Object?>{
    'pullId': pullId,
    'reference': reference,
    'platform': ?platform,
  });

  /// Cancels the local wait for [pullId] (unknown ids are ignored).
  Future<Map<String, Object?>> imagePullCancel(String pullId) => _invoke(
    ContainerBridgeMethods.imagePullCancel,
    <String, Object?>{'pullId': pullId},
  );
}

/// Typed wrapper over the event channel (log streams, pull progress, …).
class ContainerBridgeEvents {
  ContainerBridgeEvents({EventChannel? channel})
    : _channel = channel ?? const EventChannel(ContainerBridgeChannels.events);

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

  /// Raw `image.pull` progress maps for ALL pulls:
  /// {pullId, description?, completedBytes, totalBytes?, itemsDone?,
  /// itemsTotal?}. Filter by pullId downstream.
  Stream<Map<String, Object?>> imagePull() {
    return _channel
        .receiveBroadcastStream(<String, Object?>{
          'stream': ContainerBridgeStreams.imagePull,
        })
        .map((event) => (event as Map).cast<String, Object?>());
  }
}
