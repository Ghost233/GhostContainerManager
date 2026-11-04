library;

/// Raw result of a CLI invocation executed on the native side.
///
/// The bridge never interprets stdout/stderr; parsing and validation happen
/// in the Service layer (E02: validate at the boundary before forming
/// business data — the parser lives in `lib/services/system_parser.dart`).
class BridgeCommandResult {
  const BridgeCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.outputMayBeIncomplete = false,
  });

  factory BridgeCommandResult.fromMap(Map<Object?, Object?> map) {
    return BridgeCommandResult(
      exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
      stdout: (map['stdout'] as String?) ?? '',
      stderr: (map['stderr'] as String?) ?? '',
      timedOut: (map['timedOut'] as bool?) ?? false,
      outputMayBeIncomplete: (map['outputMayBeIncomplete'] as bool?) ?? true,
    );
  }

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  /// The bounded process replay buffer overflowed; callers requiring complete
  /// output must reject the result even when the command exited successfully.
  final bool outputMayBeIncomplete;

  bool get ok => exitCode == 0 && !timedOut;

  /// Combined text used for error-feature matching.
  String get combinedOutput => '$stdout\n$stderr';
}

/// Live generic CLI process with line-oriented, independently drained output.
///
/// Implementations retain output produced before a listener attaches and
/// complete [exitCode] after the native side has drained both pipes.
abstract class BridgeCliProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;

  /// Terminates the whole native process group. Repeated calls are safe.
  Future<void> terminate();
}

/// Result of a one-shot, non-TTY process in a running container.
class BridgeExecResult {
  const BridgeExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
    this.timedOut = false,
  });

  factory BridgeExecResult.fromMap(Map<Object?, Object?> map) {
    return BridgeExecResult(
      exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
      stdout: (map['stdout'] as String?) ?? '',
      stderr: (map['stderr'] as String?) ?? '',
      stdoutTruncated: (map['stdoutTruncated'] as bool?) ?? false,
      stderrTruncated: (map['stderrTruncated'] as bool?) ?? false,
      timedOut: (map['timedOut'] as bool?) ?? false,
    );
  }

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool stdoutTruncated;
  final bool stderrTruncated;
  final bool timedOut;

  bool get truncated => stdoutTruncated || stderrTruncated;
}

class BridgePingResult {
  const BridgePingResult.ok({
    required this.apiServerVersion,
    this.appRoot,
    this.installRoot,
  }) : error = null;

  const BridgePingResult.failure(this.error)
    : apiServerVersion = null,
      appRoot = null,
      installRoot = null;

  factory BridgePingResult.fromMap(Map<Object?, Object?> map) {
    final ok = (map['ok'] as bool?) ?? false;
    if (!ok) {
      return BridgePingResult.failure(
        (map['error'] as String?) ?? 'unknown ping failure',
      );
    }
    return BridgePingResult.ok(
      apiServerVersion: map['apiServerVersion'] as String?,
      appRoot: map['appRoot'] as String?,
      installRoot: map['installRoot'] as String?,
    );
  }

  final String? apiServerVersion;
  final String? appRoot;
  final String? installRoot;
  final String? error;

  bool get ok => error == null;
}

class BridgeLogEvent {
  const BridgeLogEvent.data({required this.source, required this.bytes})
    : event = 'data',
      message = null;

  const BridgeLogEvent.eof()
    : event = 'eof',
      source = '',
      bytes = const <int>[],
      message = null;

  const BridgeLogEvent.error(this.message)
    : event = 'error',
      source = '',
      bytes = const <int>[];

  /// 'data' | 'eof' | 'error'.
  final String event;

  /// 'stdio' | 'boot' (only for data events).
  final String source;

  /// Raw bytes; UTF-8 sequences may span chunk boundaries, so decode with
  /// a streaming decoder (the Service layer does).
  final List<int> bytes;

  /// Error text for error events.
  final String? message;
}

/// One progress sample on the `image.pull` event stream. The Swift side
/// folds the granular upstream ProgressUpdateEvent stream into byte/item
/// counters throttled to ~10 Hz (single throttle point shared by the UI and
/// MCP progress notifications).
class BridgeImagePullEvent {
  const BridgeImagePullEvent({
    required this.pullId,
    this.description,
    this.completedBytes = 0,
    this.totalBytes,
    this.itemsDone,
    this.itemsTotal,
  });

  factory BridgeImagePullEvent.fromMap(Map<Object?, Object?> map) {
    return BridgeImagePullEvent(
      pullId: (map['pullId'] as String?) ?? '',
      description: map['description'] as String?,
      completedBytes: (map['completedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt(),
      itemsDone: (map['itemsDone'] as num?)?.toInt(),
      itemsTotal: (map['itemsTotal'] as num?)?.toInt(),
    );
  }

  final String pullId;
  final String? description;
  final int completedBytes;
  final int? totalBytes;
  final int? itemsDone;
  final int? itemsTotal;
}

class BridgeCallException implements Exception {
  const BridgeCallException(this.message);

  final String message;

  @override
  String toString() => 'BridgeCallException($message)';
}

/// Opt-in command seam that explicitly reports potentially incomplete output.
abstract interface class CompleteOutputContainerBridge {
  Future<BridgeCommandResult> cliRunForIdentity(List<String> arguments);
}

abstract interface class ContainerBridge {
  /// Absolute path of the `container` CLI, or null when not installed.
  ///
  /// Probes, in order: [customPath], /usr/local/bin/container,
  /// /opt/homebrew/bin/container.
  Future<String?> locateBinary({String? customPath});

  /// `docker version --format '{{json .}}'`.
  Future<BridgeCommandResult> systemVersion();

  /// `docker info --format '{{json .}}'`.
  Future<BridgeCommandResult> systemStatus();

  Future<BridgePingResult> ping();

  /// Runs an arbitrary `container` CLI argument vector. The bridge performs
  /// no quoting, parsing, or business validation and returns raw output.
  Future<BridgeCommandResult> cliRun(
    List<String> arguments, {
    Duration? timeout,
  });

  /// Starts a generic CLI process and returns its handle synchronously.
  /// Launch failures are delivered through [BridgeCliProcess.exitCode].
  BridgeCliProcess cliStart(List<String> arguments);

  Future<List<Map<String, Object?>>> containerList();

  Future<Map<String, Object?>> containerInspect(String id);

  Future<Map<String, Object?>> containerStats(String id);

  Future<void> containerCreate({
    required String id,
    required String image,
    List<String> command = const [],
    List<String> env = const [],
    List<String> ports = const [],
    String? network,
    List<Map<String, Object?>> mounts = const [],
    Map<String, String> labels = const {},
  });

  Future<void> containerStart(String id);

  Future<bool> containerStop(String id, {int timeoutSeconds = 5});

  Future<void> containerDelete(String id, {bool force = false});

  Future<String> containerKill(String id, {String signal = 'KILL'});

  /// Execute a one-shot non-TTY process. Output is captured independently and
  /// the process exit code is data, not a bridge failure.
  Future<BridgeExecResult> containerExec({
    required String id,
    required List<String> command,
    List<String> env = const [],
    String? workdir,
    String? user,
    int timeoutSeconds = 60,
  });

  Stream<BridgeLogEvent> containerLogs(String id);

  // -- network domain (T6, read-only) ---------------------------------------

  Future<BridgeCommandResult> networkList();

  /// `container network inspect <id>` (CLI; JSON output by default).
  Future<BridgeCommandResult> networkInspect(String id);

  // -- compose domain (T6, plugin CLI route) --------------------------------

  Future<BridgeCommandResult> composeHelp();

  /// `docker compose <arguments>` — executes the compose plugin. The
  /// argument vector is built by the Service layer (flag decisions live
  /// there); this seam only forwards and reports raw output.
  ///
  /// [timeout] defaults to the plugin-side default (600s on the native
  /// side); `up` of a cold image set can legitimately take minutes.
  Future<BridgeCommandResult> composeRun(
    List<String> arguments, {
    Duration? timeout,
  });

  Future<List<Map<String, Object?>>> imageList();

  Future<Map<String, Object?>> imageInspect(String reference);

  Future<void> imageDelete(String reference);

  Future<Map<String, Object?>> imagePull({
    required String pullId,
    required String reference,
    String? platform,
  });

  /// Cancels the local wait for [pullId]; the pending [imagePull] resolves
  /// with `cancelled: true`. Unknown ids are ignored.
  Future<void> imagePullCancel(String pullId);

  /// Broadcast stream of throttled pull progress events (all pulls;
  /// consumers filter by [BridgeImagePullEvent.pullId]).
  Stream<BridgeImagePullEvent> imagePullEvents();
}
