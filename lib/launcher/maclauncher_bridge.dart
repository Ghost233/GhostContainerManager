import 'dart:async';
import 'dart:collection';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import '../services/container_logs_parser.dart';
import '../services/container_models.dart';
import '../services/container_service.dart';

/// Builds the pinned MacLauncher SDK client.
///
/// This is the only production library that depends on MacLauncher SDK types.
typedef MacLauncherSdkConnector = MacLauncherSdk Function({
  required String projectId,
  required String projectName,
  required SdkEntry? entry,
  required Map<String, ServiceCallbacks> services,
});

/// Exposes managed containers as MacLauncher services.
class MacLauncherBridge {
  MacLauncherBridge({
    required ContainerService containers,
    MacLauncherSdkConnector? sdkConnector,
  }) : this._(containers, sdkConnector);

  MacLauncherBridge._(this._containers, MacLauncherSdkConnector? sdkConnector)
    : _sdkConnector = sdkConnector ?? _connectSdk;

  static const projectId = 'com.ghost233.ghostcontainermanager';
  static const projectName = 'Ghost Container Manager';
  static const managedLabelPrefix = 'com.ghost233.';
  // A fixed window, not an idle timeout: continuous producers cannot starve it.
  static const _logBatchWindow = Duration(milliseconds: 250);

  final ContainerService _containers;
  final MacLauncherSdkConnector _sdkConnector;
  final _activeLogReads = <_LogRead>{};

  MacLauncherSdk? _sdk;
  Future<void>? _connectFuture;
  StreamSubscription<List<ContainerSnapshotInfo>>? _snapshotSubscription;
  List<ContainerSnapshotInfo>? _pendingSnapshots;
  var _registeredServiceIds = <String>{};
  var _synchronizing = false;
  var _disposed = false;

  /// Announces current containers. Concurrent callers share one connection.
  Future<void> connect() {
    if (_disposed) {
      return Future<void>.error(StateError('MacLauncherBridge is disposed'));
    }
    return _connectFuture ??= _connectOnce();
  }

  Future<void> _connectOnce() async {
    try {
      if (_sdk != null) return;

      final snapshots = await _containers.listContainers(
        const ContainerQuery(),
      );
      if (_disposed) throw StateError('MacLauncherBridge is disposed');
      await _replaceRegistrations(snapshots);
      if (_disposed) throw StateError('MacLauncherBridge is disposed');
      _snapshotSubscription ??= _containers.snapshots.listen(_queueSync);
    } on Object {
      _connectFuture = null;
      rethrow;
    }
  }

  Map<String, ServiceCallbacks> _servicesFor(
    List<ContainerSnapshotInfo> snapshots,
  ) {
    return <String, ServiceCallbacks>{
      for (final container in snapshots)
        if (container.labels.keys.any(
          (key) => key.startsWith(managedLabelPrefix),
        ))
          container.id: ServiceCallbacks(
            name: container.id,
            onStart: () => _containers.start(container.id),
            onRecycle: () => _containers.restart(container.id),
            onStatus: () => _statusFor(container.id),
            onLogs: (query) => _logsFor(container.id, query),
          ),
    };
  }

  void _queueSync(List<ContainerSnapshotInfo> snapshots) {
    _pendingSnapshots = snapshots;
    if (_synchronizing || _disposed) return;
    _synchronizing = true;
    unawaited(_drainSync());
  }

  Future<void> _drainSync() async {
    try {
      while (!_disposed) {
        final snapshots = _pendingSnapshots;
        if (snapshots == null) break;
        _pendingSnapshots = null;
        try {
          await _replaceRegistrations(snapshots);
        } on Object {
          // Keep the last healthy registration. A later snapshot retries.
        }
      }
    } finally {
      _synchronizing = false;
      if (_pendingSnapshots != null && !_disposed) {
        _queueSync(_pendingSnapshots!);
      }
    }
  }

  Future<void> _replaceRegistrations(
    List<ContainerSnapshotInfo> snapshots,
  ) async {
    final services = _servicesFor(snapshots);
    final serviceIds = services.keys.toSet();
    if (_sdk != null && _sameIds(serviceIds, _registeredServiceIds)) return;

    final previous = _sdk;
    _sdk = null;
    await previous?.dispose();
    if (_disposed) return;

    _sdk = _sdkConnector(
      projectId: projectId,
      projectName: projectName,
      entry: SdkEntry.currentAppBundle() ?? SdkEntry.currentExecutable(),
      services: services,
    );
    _registeredServiceIds = serviceIds;
  }

  bool _sameIds(Set<String> left, Set<String> right) {
    return left.length == right.length && left.containsAll(right);
  }

  Future<ServiceStatus> _statusFor(String id) async {
    final snapshot = await _containers.inspect(id);
    return ServiceStatus(
      state: _serviceState(snapshot.state, _containers.activityFor(id)),
    );
  }

  ServiceState _serviceState(
    ContainerState state,
    ContainerActivity? activity,
  ) {
    if (activity != null) {
      return switch (activity) {
        ContainerActivity.creating ||
        ContainerActivity.starting => ServiceState.starting,
        ContainerActivity.stopping ||
        ContainerActivity.deleting => ServiceState.stopping,
        ContainerActivity.restarting => switch (state) {
          ContainerState.stopped => ServiceState.starting,
          ContainerState.running ||
          ContainerState.stopping => ServiceState.stopping,
          ContainerState.unknown => ServiceState.unknown,
        },
      };
    }
    return switch (state) {
      ContainerState.stopped => ServiceState.stopped,
      ContainerState.running => ServiceState.running,
      ContainerState.stopping => ServiceState.stopping,
      ContainerState.unknown => ServiceState.unknown,
    };
  }

  Future<LogBatch> _logsFor(String id, LogQuery query) async {
    if (_disposed) throw StateError('MacLauncherBridge is disposed');

    final entries = ListQueue<LogEntry>();
    final pending = <String, StringBuffer>{};
    final lastChunk = <String, int>{};
    final read = _LogRead();
    var chunkSequence = 0;
    var truncated = false;
    var reachedEnd = false;
    Timer? window;

    void addLine(String text, String source) {
      if (text.endsWith('\r')) {
        text = text.substring(0, text.length - 1);
      }
      if (entries.length == query.limit) {
        entries.removeFirst();
        truncated = true;
      }
      entries.add(LogEntry(text: text, stream: _logStreamFor(source)));
    }

    try {
      read.subscription = _containers
          .logs(id)
          .listen(
            (event) {
              if (read.done.isCompleted) return;
              try {
                if (event.kind == 'eof') {
                  reachedEnd = true;
                  read.done.complete();
                  return;
                }
                if (event.kind == 'error') {
                  read.done.completeError(
                    StateError(event.message ?? 'container log stream failed'),
                  );
                  return;
                }
                if (event.kind != 'data') return;

                final source = event.source;
                final buffer = pending.putIfAbsent(source, StringBuffer.new);
                buffer.write(event.text);
                lastChunk[source] = chunkSequence++;
                final lines = buffer.toString().split('\n');
                buffer.clear();
                buffer.write(lines.removeLast());
                for (final line in lines) {
                  addLine(line, source);
                }
              } catch (error, stackTrace) {
                read.done.completeError(error, stackTrace);
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!read.done.isCompleted) {
                read.done.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!read.done.isCompleted) {
                reachedEnd = true;
                read.done.complete();
              }
            },
          );
      window = Timer(_logBatchWindow, () {
        if (!read.done.isCompleted) read.done.complete();
      });
      _activeLogReads.add(read);
      await read.done.future;
      if (_disposed) throw StateError('MacLauncherBridge is disposed');

      final tailSources =
          pending.keys.where((source) => pending[source]!.isNotEmpty).toList()
            ..sort((a, b) => lastChunk[a]!.compareTo(lastChunk[b]!));
      for (final source in tailSources) {
        addLine(pending[source]!.toString(), source);
      }

      return LogBatch(
        entries: entries.toList(),
        // A time-window read cannot know whether more history exists.
        truncated: truncated ? true : (reachedEnd ? false : null),
        observedAt: DateTime.now().toUtc(),
      );
    } finally {
      window?.cancel();
      if (_activeLogReads.remove(read)) {
        await read.subscription.cancel();
      }
    }
  }

  LogStream _logStreamFor(String source) {
    // Apple container stdio cannot reliably split stdout from stderr.
    // Runtime/VM boot diagnostics use the SDK's non-stdio app channel.
    return source == 'boot' ? LogStream.app : LogStream.unknown;
  }

  /// Releases launcher resources; container writes are left untouched.
  Future<void> dispose() async {
    _disposed = true;
    final sdk = _sdk;
    _sdk = null;
    final subscription = _snapshotSubscription;
    _snapshotSubscription = null;
    _pendingSnapshots = null;
    final reads = _activeLogReads.toList();
    _activeLogReads.clear();
    try {
      await Future.wait([
        ...reads.map((read) => read.cancel()),
        if (subscription != null) subscription.cancel(),
      ]);
    } finally {
      await sdk?.dispose();
    }
  }
}

class _LogRead {
  final done = Completer<void>();
  late final StreamSubscription<ContainerLogEvent> subscription;

  Future<void> cancel() {
    if (!done.isCompleted) {
      done.completeError(StateError('MacLauncherBridge is disposed'));
    }
    return subscription.cancel();
  }
}

MacLauncherSdk _connectSdk({
  required String projectId,
  required String projectName,
  required SdkEntry? entry,
  required Map<String, ServiceCallbacks> services,
}) {
  return MacLauncherSdk.connect(
    projectId: projectId,
    projectName: projectName,
    entry: entry,
    services: services,
  );
}
