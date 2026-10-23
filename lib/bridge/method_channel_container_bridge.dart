/// Real [ContainerBridge] backed by the `container_bridge` plugin
/// (MethodChannel → Swift: ContainerAPIClient over XPC + CLI runner).
///
/// Pure-local probes (locating the CLI binary, checking the default-kernel
/// symlink) use dart:io directly — no channel roundtrip.
library;

import 'dart:io';

import 'package:container_bridge/container_bridge.dart';
import 'package:flutter/services.dart';

import 'container_bridge.dart' as seam;

class MethodChannelContainerBridge implements seam.ContainerBridge {
  MethodChannelContainerBridge({
    ContainerBridgeChannel? channel,
    ContainerBridgeEvents? events,
  }) : _channel = channel ?? ContainerBridgeChannel(),
       _events = events ?? ContainerBridgeEvents();

  /// Candidate install locations probed by [locateBinary], in order.
  static const defaultBinaryCandidates = <String>[
    '/usr/local/bin/container',
    '/opt/homebrew/bin/container',
  ];

  final ContainerBridgeChannel _channel;
  final ContainerBridgeEvents _events;

  @override
  Future<String?> locateBinary({String? customPath}) async {
    for (final path in [?customPath, ...defaultBinaryCandidates]) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  @override
  Future<seam.BridgeCommandResult> systemVersion() =>
      _command(() => _channel.systemVersion());

  @override
  Future<seam.BridgeCommandResult> systemStatus() =>
      _command(() => _channel.systemStatus());

  @override
  Future<seam.BridgeCommandResult> systemStart({required bool installKernel}) =>
      _command(() => _channel.systemStart(installKernel: installKernel));

  @override
  Future<seam.BridgeCommandResult> systemStop() =>
      _command(() => _channel.systemStop());

  @override
  Future<seam.BridgeCommandResult> kernelSetRecommended({bool force = false}) =>
      _command(() => _channel.systemKernelSet(force: force));

  @override
  Future<bool> kernelInstalled() async {
    final home = Platform.environment['HOME'];
    if (home == null) return false;
    return Link(
      '$home/Library/Application Support/com.apple.container/kernels/default.kernel-arm64',
    ).existsSync();
  }

  @override
  Future<seam.BridgePingResult> ping() async {
    try {
      return seam.BridgePingResult.fromMap(await _channel.systemPing());
    } on PlatformException catch (e) {
      return seam.BridgePingResult.failure(e.message ?? e.code);
    }
  }

  @override
  Future<List<Map<String, Object?>>> containerList() async {
    try {
      return await _channel.containerList();
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Future<Map<String, Object?>> containerInspect(String id) async {
    try {
      return await _channel.containerGet(id);
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Future<Map<String, Object?>> containerStats(String id) async {
    try {
      return await _channel.containerStats(id);
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Stream<seam.BridgeLogEvent> containerLogs(String id) {
    return _events.containerLogs(id).map(_toLogEvent);
  }

  @override
  Future<seam.BridgeCommandResult> networkList() =>
      _command(() => _channel.networkList());

  @override
  Future<seam.BridgeCommandResult> networkInspect(String id) =>
      _command(() => _channel.networkInspect(id));

  @override
  Future<seam.BridgeCommandResult> composeHelp() =>
      _command(() => _channel.composeHelp());

  @override
  Future<seam.BridgeCommandResult> composeRun(
    List<String> arguments, {
    Duration? timeout,
  }) => _command(
    () => _channel.composeRun(arguments, timeoutSeconds: timeout?.inSeconds),
  );

  // -- image domain (T5) -----------------------------------------------------

  @override
  Future<List<Map<String, Object?>>> imageList() async {
    try {
      return await _channel.imageList();
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Future<Map<String, Object?>> imageInspect(String reference) async {
    try {
      return await _channel.imageInspect(reference);
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Future<void> imageDelete(String reference) async {
    try {
      await _channel.imageDelete(reference);
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Future<Map<String, Object?>> imagePull({
    required String pullId,
    required String reference,
    String? platform,
  }) async {
    try {
      return await _channel.imagePull(
        pullId: pullId,
        reference: reference,
        platform: platform,
      );
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Future<void> imagePullCancel(String pullId) async {
    try {
      await _channel.imagePullCancel(pullId);
    } on PlatformException catch (e) {
      throw seam.BridgeCallException(e.message ?? e.code);
    }
  }

  @override
  Stream<seam.BridgeImagePullEvent> imagePullEvents() {
    return _events.imagePull().map(seam.BridgeImagePullEvent.fromMap);
  }

  static seam.BridgeLogEvent _toLogEvent(Map<String, Object?> event) {
    final kind = event['event'] as String? ?? 'data';
    switch (kind) {
      case 'eof':
        return const seam.BridgeLogEvent.eof();
      case 'error':
        return seam.BridgeLogEvent.error(event['message'] as String? ?? '');
      default:
        final raw = event['data'];
        return seam.BridgeLogEvent.data(
          source: event['source'] as String? ?? 'stdio',
          bytes: raw is Uint8List ? raw : Uint8List(0),
        );
    }
  }

  Future<seam.BridgeCommandResult> _command(
    Future<Map<String, Object?>> Function() call,
  ) async {
    try {
      return seam.BridgeCommandResult.fromMap(await call());
    } on PlatformException catch (e) {
      return seam.BridgeCommandResult(
        exitCode: -1,
        stdout: '',
        stderr: e.message ?? e.code,
      );
    }
  }
}
