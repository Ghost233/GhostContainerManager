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

/// Failure of an XPC bridge call. [message] carries the raw native error
/// text so the Service layer can classify it by feature (same fingerprint
/// approach as `mapBridgeFailure`).
class BridgeCallException implements Exception {
  const BridgeCallException(this.message);

  final String message;

  @override
  String toString() => 'BridgeCallException($message)';
}

/// Native runtime operations needed by the Service layer (system domain
/// first; container/image/project domains extend this seam later).
abstract interface class ContainerBridge {
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
  Future<BridgeCommandResult> systemStart({required bool installKernel});

  /// `container system stop`.
  Future<BridgeCommandResult> systemStop();

  /// `container system kernel set --recommended` (+ `--force` on retry after
  /// an "already exists" failure).
  Future<BridgeCommandResult> kernelSetRecommended({bool force = false});

  /// Whether the default kernel symlink
  /// (~/Library/Application Support/com.apple.container/kernels/
  /// default.kernel-arm64) exists.
  Future<bool> kernelInstalled();

  /// XPC health-check ping (`ClientHealthCheck.ping()`). Fails when the
  /// apiserver is not running ("connection invalid") or when the wire format
  /// is incompatible ("failed to decode ... in health check").
  Future<BridgePingResult> ping();

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

  /// Log byte stream for [id] (XPC fd handover: stdio + boot handles).
  /// UI-only surface — MCP deliberately has no logs tool (#13 decision).
  Stream<BridgeLogEvent> containerLogs(String id);
}
