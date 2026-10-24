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
import 'dart:convert';

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

/// A transient Service-layer activity. Native [ContainerState] remains a
/// four-state runtime fact; these values describe an in-flight write and are
/// shared by every UI/MCP subscriber rather than being written into raw JSON.
enum ContainerActivity { creating, starting, stopping, restarting, deleting }

enum _ContainerWriteKind { create, start, stop, restart, delete, kill, exec }

/// Exit code and bounded, separately captured output from a one-shot process.
class ContainerExecResult {
  const ContainerExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
  });

  static const int maxOutputBytes = 64 * 1024;

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  bool get truncated => stdoutTruncated || stderrTruncated;

  Map<String, Object?> toJson() => <String, Object?>{
    'exitCode': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'truncated': truncated,
  };
}

/// Read and write side of the container domain: snapshots, adaptive refresh
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
  final StreamController<Map<String, ContainerActivity>> _activityChanges =
      StreamController<Map<String, ContainerActivity>>.broadcast();
  final Map<String, ContainerActivity> _activities =
      <String, ContainerActivity>{};
  final Map<String, List<_PendingContainerOperation<dynamic>>> _operations =
      <String, List<_PendingContainerOperation<dynamic>>>{};

  Timer? _pollTimer;
  bool _refreshInFlight = false;
  List<ContainerSnapshotInfo> _lastSnapshot = const [];

  /// Broadcast stream of parsed snapshots, one event per successful refresh.
  Stream<List<ContainerSnapshotInfo>> get snapshots => _snapshots.stream;

  /// Latest parsed or optimistically reconciled snapshots.
  List<ContainerSnapshotInfo> get currentContainers =>
      List<ContainerSnapshotInfo>.unmodifiable(_lastSnapshot);

  /// Current transient writes keyed by container id.
  Map<String, ContainerActivity> get currentActivities =>
      Map<String, ContainerActivity>.unmodifiable(_activities);

  Stream<Map<String, ContainerActivity>> get activityChanges =>
      _activityChanges.stream;

  ContainerActivity? activityFor(String id) => _activities[id];

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
      final pendingCreates = _lastSnapshot.where(
        (container) =>
            _activities[container.id] == ContainerActivity.creating &&
            !parsed.any((candidate) => candidate.id == container.id),
      );
      _lastSnapshot = <ContainerSnapshotInfo>[...parsed, ...pendingCreates];
      if (!_snapshots.isClosed) _snapshots.add(currentContainers);
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

  /// Execute one non-TTY process in a running container. A non-zero process
  /// exit is returned as data; bridge/runtime failures remain structured
  /// exceptions. stdout and stderr are independently capped at 64 KiB.
  Future<ContainerExecResult> exec(
    String id, {
    required List<String> command,
    Map<String, String> env = const {},
    String? workdir,
    String? user,
    int timeoutSeconds = 60,
  }) {
    final containerId = _validId(id);
    if (command.isEmpty || command.first.trim().isEmpty) {
      return Future<ContainerExecResult>.error(
        const GcmException(
          GcmErrorCode.invalidArgument,
          'Exec command must contain a non-empty executable.',
        ),
      );
    }
    if (timeoutSeconds < 1 || timeoutSeconds > 600) {
      return Future<ContainerExecResult>.error(
        const GcmException(
          GcmErrorCode.invalidArgument,
          'Exec timeout must be between 1 and 600 seconds.',
        ),
      );
    }
    for (final entry in env.entries) {
      if (entry.key.isEmpty ||
          entry.key.contains('=') ||
          entry.key.contains('\u0000') ||
          entry.value.contains('\u0000')) {
        return Future<ContainerExecResult>.error(
          GcmException(
            GcmErrorCode.invalidArgument,
            'Invalid exec environment entry: "${entry.key}".',
          ),
        );
      }
    }
    final current = _containerOrNull(containerId);
    if (current != null && current.state != ContainerState.running) {
      return Future<ContainerExecResult>.error(
        GcmException(
          GcmErrorCode.conflict,
          'Container "$containerId" is not running; exec requires a running '
          'container.',
          hint: 'Start the container first.',
        ),
      );
    }
    final environment = env.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .toList(growable: false);
    return _enqueue<ContainerExecResult>(
      id: containerId,
      kind: _ContainerWriteKind.exec,
      activity: null,
      action: () async {
        final inspected = await inspect(containerId);
        if (inspected.state != ContainerState.running) {
          throw GcmException(
            GcmErrorCode.conflict,
            'Container "$containerId" is not running; exec requires a '
            'running container.',
            hint: 'Start the container first.',
          );
        }
        final result = await _bridge.containerExec(
          id: containerId,
          command: command,
          env: environment,
          workdir: workdir,
          user: user,
          timeoutSeconds: timeoutSeconds,
        );
        if (result.timedOut) {
          throw GcmException(
            GcmErrorCode.timeout,
            'Exec in container "$containerId" timed out after '
            '$timeoutSeconds seconds.',
            hint: 'The process may still be running inside the container.',
            source: 'xpc',
          );
        }
        final stdout = _boundedOutput(result.stdout);
        final stderr = _boundedOutput(result.stderr);
        return ContainerExecResult(
          exitCode: result.exitCode,
          stdout: stdout.value,
          stderr: stderr.value,
          stdoutTruncated: result.stdoutTruncated || stdout.truncated,
          stderrTruncated: result.stderrTruncated || stderr.truncated,
        );
      },
    );
  }

  /// Create a container from a local image and optionally start it.
  Future<String> create({
    String? id,
    required String image,
    List<String> command = const [],
    List<String> env = const [],
    List<String> ports = const [],
    String? network,
    bool start = false,
  }) {
    final containerId = id == null ? _generatedContainerId() : _validId(id);
    final reference = image.trim();
    if (reference.isEmpty) {
      return Future<String>.error(
        const GcmException(GcmErrorCode.invalidArgument, 'Image is required.'),
      );
    }
    for (final variable in env) {
      final equals = variable.indexOf('=');
      if (equals <= 0) {
        return Future<String>.error(
          GcmException(
            GcmErrorCode.invalidArgument,
            'Environment entries must use KEY=VALUE: "$variable".',
          ),
        );
      }
    }
    if (ports.any((port) => port.trim().isEmpty) ||
        (network != null && network.trim().isEmpty)) {
      return Future<String>.error(
        const GcmException(
          GcmErrorCode.invalidArgument,
          'Ports and network must not be blank.',
        ),
      );
    }

    final previous = _containerOrNull(containerId);
    if (previous == null) {
      _upsertContainer(containerId, ContainerState.stopped, image: reference);
    }
    var created = false;
    return _enqueue<String>(
      id: containerId,
      kind: _ContainerWriteKind.create,
      activity: ContainerActivity.creating,
      action: () async {
        try {
          await _bridge.containerCreate(
            id: containerId,
            image: reference,
            command: command,
            env: env,
            ports: ports,
            network: network?.trim(),
          );
          created = true;
          if (start) {
            _setActivity(containerId, ContainerActivity.starting);
            await _bridge.containerStart(containerId);
          }
          _upsertContainer(
            containerId,
            start ? ContainerState.running : ContainerState.stopped,
            image: reference,
          );
          return containerId;
        } catch (_) {
          if (!created && previous == null) _removeContainer(containerId);
          rethrow;
        }
      },
    );
  }

  Future<void> start(String id) {
    final containerId = _validId(id);
    return _enqueue<void>(
      id: containerId,
      kind: _ContainerWriteKind.start,
      activity: ContainerActivity.starting,
      action: () async {
        await _bridge.containerStart(containerId);
        _upsertContainer(containerId, ContainerState.running);
      },
    );
  }

  Future<void> stop(String id, {int timeoutSeconds = 5}) {
    final containerId = _validId(id);
    final timeout = _validTimeout(timeoutSeconds);
    return _enqueue<void>(
      id: containerId,
      kind: _ContainerWriteKind.stop,
      activity: ContainerActivity.stopping,
      action: () async {
        await _bridge.containerStop(containerId, timeoutSeconds: timeout);
        _upsertContainer(containerId, ContainerState.stopped);
      },
    );
  }

  /// Composite stop (five-second grace, then native SIGKILL) followed by
  /// start. It is intentionally not atomic and runs under one resource lock.
  Future<void> restart(String id, {int timeoutSeconds = 5}) {
    final containerId = _validId(id);
    final timeout = _validTimeout(timeoutSeconds);
    return _enqueue<void>(
      id: containerId,
      kind: _ContainerWriteKind.restart,
      activity: ContainerActivity.restarting,
      action: () async {
        await _bridge.containerStop(containerId, timeoutSeconds: timeout);
        _upsertContainer(containerId, ContainerState.stopped);
        await _bridge.containerStart(containerId);
        _upsertContainer(containerId, ContainerState.running);
      },
    );
  }

  Future<void> delete(String id, {bool force = false}) {
    final containerId = _validId(id);
    return _enqueue<void>(
      id: containerId,
      kind: _ContainerWriteKind.delete,
      activity: ContainerActivity.deleting,
      action: () async {
        ContainerSnapshotInfo? current = _containerOrNull(containerId);
        if (current == null) {
          try {
            current = await inspect(containerId);
          } on GcmException catch (error) {
            if (error.code == GcmErrorCode.notFound) {
              _removeContainer(containerId);
              return;
            }
            rethrow;
          }
        }
        if (current.state == ContainerState.stopping) {
          throw _stoppingConflict(containerId);
        }
        if (current.state == ContainerState.running && !force) {
          throw GcmException(
            GcmErrorCode.conflict,
            'Container "$containerId" is running.',
            hint: 'Stop it first, or explicitly request force deletion.',
          );
        }
        try {
          await _bridge.containerDelete(containerId, force: force);
        } on BridgeCallException catch (error) {
          final mapped = mapContainerFailure(
            error,
            operation: 'delete',
            id: containerId,
          );
          if (mapped.code != GcmErrorCode.notFound) throw mapped;
        }
        _removeContainer(containerId);
      },
    );
  }

  Future<void> kill(String id, {String signal = 'KILL'}) {
    final containerId = _validId(id);
    final normalizedSignal = signal.trim();
    if (normalizedSignal.isEmpty) {
      return Future<void>.error(
        const GcmException(GcmErrorCode.invalidArgument, 'Signal is required.'),
      );
    }
    return _enqueue<void>(
      id: containerId,
      kind: _ContainerWriteKind.kill,
      activity: null,
      action: () async {
        await _bridge.containerKill(containerId, signal: normalizedSignal);
        if (normalizedSignal == 'KILL' ||
            normalizedSignal == 'SIGKILL' ||
            normalizedSignal == '9') {
          _upsertContainer(containerId, ContainerState.stopped);
        }
      },
    );
  }

  Future<T> _enqueue<T>({
    required String id,
    required _ContainerWriteKind kind,
    required ContainerActivity? activity,
    required Future<T> Function() action,
  }) {
    final queue = _operations.putIfAbsent(
      id,
      () => <_PendingContainerOperation<dynamic>>[],
    );
    for (final pending in queue) {
      if (pending.kind == kind && kind != _ContainerWriteKind.exec) {
        return pending.future as Future<T>;
      }
    }
    if (kind == _ContainerWriteKind.delete &&
        queue.any(
          (pending) =>
              pending.kind == _ContainerWriteKind.stop ||
              pending.kind == _ContainerWriteKind.restart,
        )) {
      return Future<T>.error(_stoppingConflict(id));
    }

    final pending = _PendingContainerOperation<T>(kind);
    final previous = queue.isEmpty ? null : queue.last;
    queue.add(pending);
    if (previous == null) {
      unawaited(_execute(id, pending, activity, action));
    } else {
      unawaited(
        _runAfter(previous.future, () {
          unawaited(_execute(id, pending, activity, action));
        }),
      );
    }
    return pending.future;
  }

  Future<void> _runAfter(
    Future<dynamic> previous,
    void Function() callback,
  ) async {
    try {
      await previous;
    } catch (_) {
      // A queued operation still runs after its predecessor fails.
    }
    callback();
  }

  Future<void> _execute<T>(
    String id,
    _PendingContainerOperation<T> pending,
    ContainerActivity? activity,
    Future<T> Function() action,
  ) async {
    _setActivity(id, activity);
    try {
      pending.completer.complete(await action());
    } on GcmException catch (error, stackTrace) {
      pending.completer.completeError(error, stackTrace);
    } on BridgeCallException catch (error, stackTrace) {
      pending.completer.completeError(
        mapContainerFailure(error, operation: pending.kind.name, id: id),
        stackTrace,
      );
    } catch (error, stackTrace) {
      pending.completer.completeError(error, stackTrace);
    } finally {
      final queue = _operations[id];
      queue?.remove(pending);
      if (queue == null || queue.isEmpty) _operations.remove(id);
      _setActivity(id, null);
    }
  }

  void _setActivity(String id, ContainerActivity? activity) {
    if (activity == null) {
      _activities.remove(id);
    } else {
      _activities[id] = activity;
    }
    if (!_activityChanges.isClosed) _activityChanges.add(currentActivities);
  }

  ContainerSnapshotInfo? _containerOrNull(String id) {
    for (final container in _lastSnapshot) {
      if (container.id == id) return container;
    }
    return null;
  }

  void _upsertContainer(String id, ContainerState state, {String? image}) {
    final existing = _containerOrNull(id);
    final updated = existing == null
        ? ContainerSnapshotInfo.fromMap(<String, Object?>{
            'status': state.wireName,
            'configuration': <String, Object?>{
              'id': id,
              'image': <String, Object?>{'reference': ?image},
              'labels': <String, Object?>{},
            },
            'networks': const <Object?>[],
            'ports': const <Object?>[],
          })
        : _copyWithState(existing, state);
    final next = _lastSnapshot.where((item) => item.id != id).toList();
    next.add(updated);
    _lastSnapshot = next;
    if (!_snapshots.isClosed) _snapshots.add(currentContainers);
  }

  static ContainerSnapshotInfo _copyWithState(
    ContainerSnapshotInfo container,
    ContainerState state,
  ) {
    return ContainerSnapshotInfo(
      id: container.id,
      image: container.image,
      state: state,
      labels: container.labels,
      networks: container.networks,
      createdAt: container.createdAt,
      startedAt: state == ContainerState.stopped ? null : container.startedAt,
      initCommand: container.initCommand,
      initArguments: container.initArguments,
      environment: container.environment,
      publishedPorts: container.publishedPorts,
      stopSignal: container.stopSignal,
      rawConfiguration: container.rawConfiguration,
    );
  }

  void _removeContainer(String id) {
    final next = _lastSnapshot.where((item) => item.id != id).toList();
    if (next.length == _lastSnapshot.length) return;
    _lastSnapshot = next;
    if (!_snapshots.isClosed) _snapshots.add(currentContainers);
  }

  static String _validId(String id) {
    final value = id.trim();
    if (value.isEmpty ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(value)) {
      throw GcmException(
        GcmErrorCode.invalidArgument,
        'Container id must start with an alphanumeric character and contain '
        'only letters, numbers, dot, underscore, or dash.',
      );
    }
    return value;
  }

  static ({String value, bool truncated}) _boundedOutput(String value) {
    final bytes = utf8.encode(value);
    if (bytes.length <= ContainerExecResult.maxOutputBytes) {
      return (value: value, truncated: false);
    }
    var end = ContainerExecResult.maxOutputBytes;
    // Do not split a multi-byte UTF-8 code point at the byte budget.
    while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
      end--;
    }
    return (value: utf8.decode(bytes.sublist(0, end)), truncated: true);
  }

  static int _validTimeout(int seconds) {
    if (seconds < 0 || seconds > 0x7fffffff) {
      throw const GcmException(
        GcmErrorCode.invalidArgument,
        'Stop timeout must be between 0 and 2147483647 seconds.',
      );
    }
    return seconds;
  }

  static String _generatedContainerId() =>
      'container-${DateTime.now().microsecondsSinceEpoch}';

  static GcmException _stoppingConflict(String id) => GcmException(
    GcmErrorCode.conflict,
    'Container "$id" is stopping.',
    hint: '请等待容器停止完成后再删除；stopping 状态下 force 也不能跳过。',
  );

  /// Decoded log stream for [id] (stdio + boot sources, UTF-8 safe).
  Stream<ContainerLogEvent> logs(String id) =>
      decodeContainerLogs(_bridge.containerLogs(id));

  Future<void> dispose() async {
    stopPolling();
    await _snapshots.close();
    await _activityChanges.close();
  }
}

class _PendingContainerOperation<T> {
  _PendingContainerOperation(this.kind);

  final _ContainerWriteKind kind;
  final Completer<T> completer = Completer<T>();

  Future<T> get future => completer.future;
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

  if ((lower.contains('connection') && lower.contains('invalid')) ||
      lower.contains('xpc connection')) {
    return GcmException(
      GcmErrorCode.runtimeUnavailable,
      'The container runtime is not reachable.',
      hint: 'Start the runtime from the System page (system.start).',
      source: 'xpc',
      cause: error,
    );
  }
  if (lower.contains('failed to decode')) {
    return GcmException(
      GcmErrorCode.versionMismatch,
      'The runtime answered in an unexpected wire format during $operation.',
      hint: 'Check the container version in Settings (expected 1.6.x).',
      source: 'xpc',
      cause: error,
    );
  }
  if (lower.contains('permission denied')) {
    return GcmException(
      GcmErrorCode.permissionDenied,
      'Permission denied during $operation.',
      source: 'xpc',
      cause: error,
    );
  }
  if (lower.contains('not found') || lower.contains('does not exist')) {
    return GcmException(
      GcmErrorCode.notFound,
      'Container "${id ?? ''}" was not found.',
      hint: 'Refresh the list; it may have been deleted externally.',
      source: 'xpc',
      cause: error,
    );
  }
  if (lower.contains('not running')) {
    return GcmException(
      GcmErrorCode.conflict,
      'Container "${id ?? ''}" is not running; this operation requires a '
      'running container.',
      hint: 'Start the container first.',
      source: 'xpc',
      cause: error,
    );
  }
  if (lower.contains('already exists') ||
      lower.contains('is running') ||
      lower.contains('is stopping') ||
      lower.contains('invalid state') ||
      lower.contains('state conflict')) {
    return GcmException(
      GcmErrorCode.conflict,
      'Container $operation conflicts with the current state of '
      '"${id ?? ''}": $message',
      hint: lower.contains('stopping')
          ? 'Wait for the container to stop before deleting it.'
          : 'Refresh the container state and retry with compatible options.',
      source: 'xpc',
      cause: error,
    );
  }
  return GcmException(
    GcmErrorCode.internal,
    'Container $operation failed: $message',
    source: 'xpc',
    cause: error,
  );
}
