import 'dart:async';
import 'dart:io';

import 'container_models.dart';
import 'container_service.dart';
import 'errors.dart';
import 'image_models.dart';
import 'image_service.dart';
import 'project_service.dart';

/// Progress for registry startup, including the first registry image pull.
class RegistryProgress {
  const RegistryProgress({
    required this.message,
    this.completedBytes = 0,
    this.totalBytes,
  });

  final String message;
  final int completedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (completedBytes / total).clamp(0.0, 1.0).toDouble();
  }
}

/// A fresh, health-checked view of the app-owned local registry.
class RegistryStatus {
  const RegistryStatus({
    required this.running,
    required this.port,
    this.containerId,
    this.diskBytes,
  });

  final bool running;
  final int port;
  final String? containerId;
  final int? diskBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'running': running,
    'port': port,
    'containerId': ?containerId,
    'diskBytes': ?diskBytes,
  };
}

/// Owns the singleton registry container without owning its persistent data.
///
/// Container lifecycle and image pull stay in their existing services. The
/// injected [ProjectCli] is needed only for the initial `run`, because the
/// generic container-create seam cannot express a loopback host address.
class RegistryService {
  factory RegistryService({
    required ContainerService containers,
    required ImageService images,
    required ProjectCli cli,
    String? dataDirectory,
    Future<bool> Function(int port)? probe,
  }) => RegistryService._(
    containers,
    images,
    cli,
    dataDirectory: dataDirectory,
    probe: probe,
  );

  RegistryService._(
    this._containers,
    this._images,
    this._cli, {
    String? dataDirectory,
    Future<bool> Function(int port)? probe,
  }) : _dataDirectory = dataDirectory ?? _defaultDataDirectory(),
       _probe = probe ?? _httpProbe;

  static const containerName = 'gcm-registry';
  static const imageReference = 'registry:2';
  static const containerPort = 5000;

  final ContainerService _containers;
  final ImageService _images;
  final ProjectCli _cli;
  final String _dataDirectory;
  final Future<bool> Function(int port) _probe;

  int _port = 5056;
  int? _startingPort;
  Future<RegistryStatus>? _startFuture;

  Future<RegistryStatus> status({int? port}) async {
    final container = await _findRegistry();
    final resolvedPort = _validatePort(
      port ?? _publishedPort(container) ?? _port,
    );
    final healthy =
        container?.state == ContainerState.running &&
        await _safeProbe(resolvedPort);
    return RegistryStatus(
      running: healthy,
      port: resolvedPort,
      containerId: container?.id,
      diskBytes: await _directorySize(),
    );
  }

  /// Starts the registry, sharing concurrent attempts for the same port.
  Future<RegistryStatus> start({
    int port = 5056,
    Stream<void>? cancellation,
    void Function(RegistryProgress progress)? onProgress,
  }) {
    final invalid = _portError(port);
    if (invalid != null) return Future<RegistryStatus>.error(invalid);
    final pending = _startFuture;
    if (pending != null) {
      if (_startingPort != port) {
        return Future<RegistryStatus>.error(
          GcmException(
            GcmErrorCode.conflict,
            'registry 正在以端口 $_startingPort 启动，不能同时改用 $port。',
          ),
        );
      }
      return pending;
    }
    late final Future<RegistryStatus> future;
    future =
        _start(
          port: port,
          cancellation: cancellation,
          onProgress: onProgress,
        ).whenComplete(() {
          if (identical(_startFuture, future)) {
            _startFuture = null;
            _startingPort = null;
          }
        });
    _startingPort = port;
    _startFuture = future;
    return future;
  }

  /// Stops the container but never deletes the container or registry data.
  Future<RegistryStatus> stop() async {
    final pending = _startFuture;
    if (pending != null) {
      try {
        await pending;
      } on Object {
        // A failed start can still leave a container that needs inspection.
      }
    }
    final container = await _findRegistry();
    if (container != null && container.state != ContainerState.stopped) {
      await _containers.stop(container.id);
    }
    return status();
  }

  Future<RegistryStatus> _start({
    required int port,
    required Stream<void>? cancellation,
    required void Function(RegistryProgress progress)? onProgress,
  }) async {
    var cancelled = false;
    String? activePullId;
    final abortSub = cancellation?.listen((_) {
      cancelled = true;
      final pullId = activePullId;
      if (pullId != null) unawaited(_images.cancelPull(pullId));
    });
    try {
      var container = await _findRegistry();
      _throwIfCancelled(cancelled);
      if (container == null) {
        await Directory(_dataDirectory).create(recursive: true);
        final pullId = _images.newPullId();
        activePullId = pullId;
        final outcome = await _images.pull(
          reference: imageReference,
          pullId: pullId,
          onProgress: (event) {
            onProgress?.call(
              RegistryProgress(
                message: event.description ?? 'Pulling $imageReference',
                completedBytes: event.completedBytes,
                totalBytes: event.totalBytes,
              ),
            );
          },
        );
        activePullId = null;
        if (cancelled || outcome is ImagePullCancelled) _throwCancelled();
        await _runCreate(port);
        _throwIfCancelled(cancelled);
        onProgress?.call(
          const RegistryProgress(
            message: 'registry container created',
            completedBytes: 1,
            totalBytes: 1,
          ),
        );
      } else {
        _checkPort(container, port);
        if (container.state != ContainerState.running) {
          await _containers.start(container.id);
        }
      }
      _port = port;

      for (var attempt = 0; attempt < 50; attempt += 1) {
        _throwIfCancelled(cancelled);
        container = await _findRegistry();
        if (container?.state == ContainerState.running &&
            await _safeProbe(port)) {
          return RegistryStatus(
            running: true,
            port: port,
            containerId: container!.id,
            diskBytes: await _directorySize(),
          );
        }
        if (attempt < 49) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      throw GcmException(
        GcmErrorCode.runtimeUnavailable,
        'registry 容器已启动，但 HTTP 健康检查未通过。',
        hint: '检查 http://127.0.0.1:$port/v2/ 与 registry 容器日志。',
        source: 'http',
      );
    } finally {
      activePullId = null;
      await abortSub?.cancel();
    }
  }

  Future<void> _runCreate(int port) async {
    final result = await _cli.run(<String>[
      'run',
      '--detach',
      '--name',
      containerName,
      '--publish',
      '127.0.0.1:$port:$containerPort',
      '--mount',
      'type=bind,source=$_dataDirectory,target=/var/lib/registry',
      imageReference,
    ]);
    if (result.exitCode != 0) {
      final detail = result.stderr.trim().isNotEmpty
          ? result.stderr.trim()
          : result.stdout.trim();
      throw GcmException(
        GcmErrorCode.internal,
        '创建 registry 容器失败：$detail',
        source: 'cli',
      );
    }
  }

  Future<ContainerSnapshotInfo?> _findRegistry() async {
    final containers = await _containers.listContainers(const ContainerQuery());
    for (final container in containers) {
      if (container.id == containerName) return container;
    }
    return null;
  }

  static int? _publishedPort(ContainerSnapshotInfo? container) {
    if (container == null) return null;
    for (final published in container.publishedPorts) {
      if (published.containerPort == containerPort) return published.hostPort;
    }
    return null;
  }

  static void _checkPort(ContainerSnapshotInfo container, int requested) {
    final actual = _publishedPort(container);
    if (actual != null && actual != requested) {
      throw GcmException(
        GcmErrorCode.conflict,
        'registry 已发布到端口 $actual，不能直接用 $requested 启动。',
        hint: '使用原端口，或先明确迁移现有 registry 容器与数据。',
      );
    }
  }

  static int _validatePort(int port) {
    final error = _portError(port);
    if (error != null) throw error;
    return port;
  }

  static GcmException? _portError(int port) {
    if (port >= 1 && port <= 65535) return null;
    return const GcmException(
      GcmErrorCode.invalidArgument,
      'registry 端口必须在 1 到 65535 之间。',
    );
  }

  Future<bool> _safeProbe(int port) async {
    try {
      return await _probe(port);
    } on Object {
      return false;
    }
  }

  Future<int?> _directorySize() async {
    final directory = Directory(_dataDirectory);
    if (!await directory.exists()) return null;
    var bytes = 0;
    try {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) bytes += await entity.length();
      }
    } on FileSystemException {
      // Status remains useful even if one data file cannot be inspected.
    }
    return bytes;
  }

  static void _throwIfCancelled(bool cancelled) {
    if (cancelled) _throwCancelled();
  }

  static Never _throwCancelled() {
    throw const GcmException(GcmErrorCode.internal, 'registry 启动已取消。');
  }

  static String _defaultDataDirectory() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      throw StateError('Cannot determine the application support directory');
    }
    return '$home/Library/Application Support/'
        'com.ghost233.ghostcontainermanager/registry';
  }

  static Future<bool> _httpProbe(int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/v2/'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
