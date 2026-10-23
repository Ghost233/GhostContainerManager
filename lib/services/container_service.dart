/// Container read service (T2a): list/inspect/stats plus adaptive polling
/// and log streams, built on the container-domain bridge seam.
///
/// UI and MCP adaptors consume this service; raw XPC/CLI concerns never
/// cross this boundary (docs/spec/architecture.md §3/§5). Filtering
/// semantics ([ContainerQuery]) live here — NOT in the XPC
/// `ContainerListFilters` regex path — so they stay unit-testable with the
/// fake bridge.
library;

// Public named parameter `bridge` keeps its name; the initializing-formals
// lint cannot apply to private fields (same pattern as mcp_server.dart).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../bridge/container_bridge.dart';
import 'container_logs_parser.dart';
import 'container_models.dart';
import 'errors.dart';

/// Filter applied to container lists (Service-layer semantics).
///
/// [label] is an exact `key=value` match (MCP `label` parameter). This is
/// deliberately NOT the XPC regex label filter — precision here, regex
/// upstream, and tests pin the exact-match behaviour.
class ContainerQuery {
  const ContainerQuery({this.includeStopped = true, this.label, this.state});

  /// When false, only running containers are returned (MCP `all: false`).
  final bool includeStopped;

  /// Exact `key=value` label match, e.g. `com.ghost233.compose.project=web`.
  final String? label;

  /// Optional exact lifecycle state filter.
  final ContainerState? state;
}

/// Read side of the container domain: snapshots, adaptive refresh
/// (2s foreground / 10s background, orchard pattern), stats, logs.
class ContainerService {
  ContainerService({
    required ContainerBridge bridge,
    Duration? foregroundInterval,
    Duration? backgroundInterval,
  }) : _bridge = bridge,
       foregroundInterval = foregroundInterval ?? const Duration(seconds: 2),
       backgroundInterval = backgroundInterval ?? const Duration(seconds: 10);

  final ContainerBridge _bridge;

  /// Poll cadence while the container page is visible.
  final Duration foregroundInterval;

  /// Poll cadence while the app is in the background.
  final Duration backgroundInterval;

  final StreamController<List<ContainerSnapshotInfo>> _snapshots =
      StreamController<List<ContainerSnapshotInfo>>.broadcast();

  Timer? _pollTimer;
  bool _refreshInFlight = false;
  List<ContainerSnapshotInfo> _lastSnapshot = const [];

  /// Broadcast stream of parsed snapshots, one event per successful refresh.
  Stream<List<ContainerSnapshotInfo>> get snapshots => _snapshots.stream;

  /// Starts adaptive polling; [foreground] selects the cadence. Calling
  /// again re-schedules — use it on app lifecycle transitions.
  void startPolling({required bool foreground}) {
    _pollTimer?.cancel();
    _schedule(foreground ? foregroundInterval : backgroundInterval);
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _schedule(Duration interval) {
    _pollTimer = Timer(interval, () async {
      await refresh();
      if (_pollTimer != null) {
        _schedule(interval);
      }
    });
  }

  /// One-shot unfiltered list from the runtime, parsed and typed.
  ///
  /// Skips concurrent refreshes (returns the last good snapshot) so a slow
  /// apiserver cannot stack up XPC calls.
  Future<List<ContainerSnapshotInfo>> refresh() async {
    if (_refreshInFlight) return _lastSnapshot;
    _refreshInFlight = true;
    try {
      final raw = await _bridge.containerList();
      final parsed = raw
          .map(ContainerSnapshotInfo.fromMap)
          .toList(growable: false);
      _lastSnapshot = parsed;
      if (!_snapshots.isClosed) _snapshots.add(parsed);
      return parsed;
    } on BridgeCallException catch (e) {
      throw mapContainerFailure(e, operation: 'list');
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Fresh list with [query] applied (Service-layer filtering).
  Future<List<ContainerSnapshotInfo>> listContainers(
    ContainerQuery query,
  ) async {
    return applyQuery(await refresh(), query);
  }

  /// Pure filter — exposed for tests.
  static List<ContainerSnapshotInfo> applyQuery(
    List<ContainerSnapshotInfo> containers,
    ContainerQuery query,
  ) {
    return containers
        .where((container) {
          if (!query.includeStopped &&
              container.state != ContainerState.running) {
            return false;
          }
          if (query.state != null && container.state != query.state) {
            return false;
          }
          final label = query.label;
          if (label != null) {
            final eq = label.indexOf('=');
            if (eq <= 0) return false;
            final key = label.substring(0, eq);
            final value = label.substring(eq + 1);
            if (container.labels[key] != value) return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  /// Full inspect (configuration included) for one container.
  Future<ContainerSnapshotInfo> inspect(String id) async {
    try {
      return ContainerSnapshotInfo.fromMap(await _bridge.containerInspect(id));
    } on BridgeCallException catch (e) {
      throw mapContainerFailure(e, operation: 'inspect', id: id);
    }
  }

  /// Single stats snapshot. Fails with [GcmErrorCode.conflict] when the
  /// container is not running (upstream behaviour) — callers that want
  /// zeros for stopped containers handle it at the adaptor.
  Future<ContainerStatsInfo> stats(String id) async {
    try {
      return ContainerStatsInfo.fromMap(await _bridge.containerStats(id));
    } on BridgeCallException catch (e) {
      throw mapContainerFailure(e, operation: 'stats', id: id);
    }
  }

  /// Decoded log stream for [id] (stdio + boot sources, UTF-8 safe).
  Stream<ContainerLogEvent> logs(String id) =>
      decodeContainerLogs(_bridge.containerLogs(id));

  Future<void> dispose() async {
    stopPolling();
    await _snapshots.close();
  }
}

/// Feature-fingerprint classification of raw bridge error text (same
/// approach as `mapBridgeFailure` in system_parser.dart).
GcmException mapContainerFailure(
  BridgeCallException error, {
  required String operation,
  String? id,
}) {
  final message = error.message;
  final lower = message.toLowerCase();

  if (lower.contains('connection invalid') ||
      lower.contains('xpc connection')) {
    return GcmException(
      GcmErrorCode.runtimeUnavailable,
      'The container runtime is not reachable.',
      hint: 'Start the runtime from the System page (system.start).',
      cause: error,
    );
  }
  if (lower.contains('failed to decode')) {
    return GcmException(
      GcmErrorCode.versionMismatch,
      'The runtime answered in an unexpected wire format during $operation.',
      hint: 'Check the container version in Settings (expected 1.6.x).',
      cause: error,
    );
  }
  if (lower.contains('permission denied')) {
    return GcmException(
      GcmErrorCode.permissionDenied,
      'Permission denied during $operation.',
      cause: error,
    );
  }
  if (lower.contains('not found') || lower.contains('does not exist')) {
    return GcmException(
      GcmErrorCode.notFound,
      'Container "${id ?? ''}" was not found.',
      hint: 'Refresh the list; it may have been deleted externally.',
      cause: error,
    );
  }
  if (lower.contains('not running')) {
    return GcmException(
      GcmErrorCode.conflict,
      'Container "${id ?? ''}" is not running; this operation requires a '
      'running container.',
      hint: 'Start the container first.',
      cause: error,
    );
  }
  return GcmException(
    GcmErrorCode.internal,
    'Container $operation failed: $message',
    cause: error,
  );
}
