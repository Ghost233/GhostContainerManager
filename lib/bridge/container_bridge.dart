/// Abstract seam between the app (Service layer / UI / MCP) and the native
/// Apple container runtime bridge.
///
/// Two implementations exist: `MethodChannelContainerBridge` (real, backed by
/// the `container_bridge` plugin: ContainerAPIClient over XPC + a CLI process
/// wrapper) and `FakeContainerBridge` (tests / no-runtime development).
/// See docs/spec/architecture.md §2/§3.
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
  });

  factory BridgeCommandResult.fromMap(Map<Object?, Object?> map) {
    return BridgeCommandResult(
      exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
      stdout: (map['stdout'] as String?) ?? '',
      stderr: (map['stderr'] as String?) ?? '',
      timedOut: (map['timedOut'] as bool?) ?? false,
    );
  }

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

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

/// Result of an XPC health-check ping against the container apiserver.
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

/// One event on a container log stream (`container.logs` event channel).
///
/// The XPC log route hands over two FileHandles (stdio + boot); the Swift
/// side forwards their bytes as [data] events tagged with [source]. The
/// stream terminates with an [eof] event (both handles closed) or an
/// [error] event.
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

/// Failure of an XPC bridge call. [message] carries the raw native error
/// text so the Service layer can classify it by feature (same fingerprint
/// approach as `mapBridgeFailure`).
class BridgeCallException implements Exception {
  const BridgeCallException(this.message);

  final String message;

  @override
  String toString() => 'BridgeCallException($message)';
}

/// Native runtime operations needed by the Service layer. The seam covers
/// system, container, image, network and compose domains; container writes
/// use ContainerAPIClient directly while network/compose retain their
/// documented CLI routes.
abstract interface class ContainerBridge {
  /// Saved Runtime data directory, or null for the runtime default.
  Future<String?> getAppRoot();

  /// Select an existing Runtime data directory, or clear the selection.
  Future<void> setAppRoot(String? path);

  /// Verify that the selected directory and its original volume are usable.
  Future<void> validateAppRoot(String path);

  /// Absolute path of the `container` CLI, or null when not installed.
  ///
  /// Probes, in order: [customPath], /usr/local/bin/container,
  /// /opt/homebrew/bin/container.
  Future<String?> locateBinary({String? customPath});

  /// `container system version --format json`.
  Future<BridgeCommandResult> systemVersion();

  /// `container system status --format json`.
  Future<BridgeCommandResult> systemStatus();

  /// `container system start` with the kernel-install flag ALWAYS explicit
  /// (`--enable-kernel-install` / `--disable-kernel-install`); without it the
  /// CLI blocks on readLine and dies with "failed to read user input".
  Future<BridgeCommandResult> systemStart({
    required bool installKernel,
    String? appRoot,
  });

  /// `container system stop`.
  Future<BridgeCommandResult> systemStop();

  /// `container system kernel set --recommended` (+ `--force` on retry after
  /// an "already exists" failure).
  Future<BridgeCommandResult> kernelSetRecommended({bool force = false});

  /// Whether the default kernel symlink
  /// (~/Library/Application Support/com.apple.container/kernels/
  /// default.kernel-arm64) exists.
  Future<bool> kernelInstalled({String? appRoot});

  /// XPC health-check ping (`ClientHealthCheck.ping()`). Fails when the
  /// apiserver is not running ("connection invalid") or when the wire format
  /// is incompatible ("failed to decode ... in health check").
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

  /// `ContainerClient.list()` — ALL containers as JSON-decoded snapshot
  /// maps. Filtering (label/status) happens in the Service layer so its
  /// semantics stay testable with the fake bridge.
  ///
  /// Throws [BridgeCallException] on XPC failure.
  Future<List<Map<String, Object?>>> containerList();

  /// `ContainerClient.get(id:)` — full snapshot (incl. configuration:
  /// image, mounts, env, ports, resources, labels).
  ///
  /// Throws [BridgeCallException] on XPC failure (e.g. unknown id).
  Future<Map<String, Object?>> containerInspect(String id);

  /// `ContainerClient.stats(id:)` — single snapshot. Streaming is the
  /// caller's job (poll 2s foreground / 10s background, orchard pattern).
  /// Fails for non-running containers.
  ///
  /// Throws [BridgeCallException] on XPC failure.
  Future<Map<String, Object?>> containerStats(String id);

  /// `ContainerClient.create(configuration:options:kernel:)` using a local
  /// image. [command] and [env] retain Apple container's CLI-shaped values;
  /// [mounts] contains source/target/readonly dictionaries. The Service
  /// validates and normalizes input; the native boundary still parses and
  /// validates runtime-specific port and mount configuration.
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

  /// `ContainerClient.bootstrap` + `ClientProcess.start`; already-running
  /// containers are an upstream idempotent no-op.
  Future<void> containerStart(String id);

  /// `ContainerClient.stop` with [timeoutSeconds] of grace (default five),
  /// after which Apple container sends SIGKILL. The returned bool is a
  /// conservative derivation: true only when the container was already
  /// stopped or the stop call completed in less than [timeoutSeconds].
  Future<bool> containerStop(String id, {int timeoutSeconds = 5});

  /// `ContainerClient.delete(id:force:)`. Running containers require force;
  /// native stopping containers are rejected regardless of force.
  Future<void> containerDelete(String id, {bool force = false});

  /// `ContainerClient.kill(id:signal:)`, followed by an inspect. Returns the
  /// container's observed runtime status after the signal was delivered.
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

  /// Log byte stream for [id] (XPC fd handover: stdio + boot handles).
  /// UI-only surface — MCP deliberately has no logs tool (#13 decision).
  Stream<BridgeLogEvent> containerLogs(String id);

  // -- network domain (T6, read-only) ---------------------------------------

  /// `container network ls --format json` (CLI route — XPC exposes no
  /// network-list surface in 1.5/1.6, and reads here are low-frequency).
  Future<BridgeCommandResult> networkList();

  /// `container network inspect <id>` (CLI; JSON output by default).
  Future<BridgeCommandResult> networkInspect(String id);

  // -- compose domain (T6, plugin CLI route) --------------------------------

  /// `container compose --help` — the official plugin-presence probe
  /// (exit 0 + subcommand listing = plugin installed). Run on every use;
  /// upgrading container wipes the plugin directory (apple/container#1617),
  /// so the result is NEVER cached.
  Future<BridgeCommandResult> composeHelp();

  /// `container compose <arguments>` — executes the compose plugin. The
  /// argument vector is built by the Service layer (flag decisions live
  /// there); this seam only forwards and reports raw output.
  ///
  /// [timeout] defaults to the plugin-side default (600s on the native
  /// side); `up` of a cold image set can legitimately take minutes.
  Future<BridgeCommandResult> composeRun(
    List<String> arguments, {
    Duration? timeout,
  });

  // -- image domain (T5, issue #20) ----------------------------------------
  // XPC image operations route to the independent
  // com.apple.container.core.container-core-images service (not the
  // apiserver router). Addressing is validated name:tag in the Service
  // layer BEFORE calls reach here — the bridge passes references verbatim.

  /// `ClientImage.list()` — ALL images (incl. infra/dangling) as
  /// ImageDescription maps: {reference, digest, mediaType, sizeBytes,
  /// createdAt?}. Dangling images arrive with tag-less references.
  ///
  /// Throws [BridgeCallException] on XPC failure.
  Future<List<Map<String, Object?>>> imageList();

  /// `ClientImage.get()` + index/manifest/config rebuild — config summary
  /// payload: {reference, digest, sizeBytes, layers, platforms, config:
  /// {env, entrypoint, cmd, exposedPorts, labels}}.
  ///
  /// Throws [BridgeCallException] on XPC failure (e.g. unknown reference).
  Future<Map<String, Object?>> imageInspect(String reference);

  /// `ClientImage.delete(reference:, garbageCollect: false)` — removes the
  /// tag; blob GC is the runtime's business. In-use pre-check happens in
  /// the Service layer (clearer error than the upstream refusal).
  ///
  /// Throws [BridgeCallException] on XPC failure.
  Future<void> imageDelete(String reference);

  /// `ClientImage.pull(...)` — pulls [reference] (validated name:tag).
  /// Progress flows on [imagePullEvents] tagged with [pullId]; the method
  /// call itself resolves with the pulled ImageDescription map, or with
  /// `{reference, cancelled: true}` after [imagePullCancel].
  ///
  /// v1 cancel semantics: no server-side cancel route exists; cancelling
  /// drops the local wait (the runtime may finish the pull in background).
  ///
  /// Throws [BridgeCallException] on XPC failure.
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
