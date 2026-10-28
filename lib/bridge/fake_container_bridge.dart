/// Scriptable fake of [ContainerBridge] for tests and no-runtime development.
///
/// Each getter returns the scripted value; CLI calls record their arguments
/// in [calls] so tests can assert e.g. that system start always carries an
/// explicit kernel-install flag.
library;

import 'dart:async';

import 'container_bridge.dart';

class FakeContainerBridge implements ContainerBridge {
  String? appRoot;
  String defaultAppRootPath = '/app/root';
  String? appRootReadError;
  String? appRootValidationError;

  @override
  Future<String?> getAppRoot() async {
    if (appRootReadError case final error?) {
      throw BridgeCallException(error);
    }
    return appRoot;
  }

  @override
  Future<String> defaultAppRoot() async => defaultAppRootPath;

  @override
  Future<void> setAppRoot(String? path) async {
    appRoot = path;
    appRootReadError = null;
  }

  @override
  Future<void> validateAppRoot(String path) async {
    if (appRootValidationError case final error?) {
      throw BridgeCallException(error);
    }
  }

  /// Probed CLI path; null simulates "not installed".
  String? binaryPath = '/opt/homebrew/bin/container';

  BridgeCommandResult versionResult = _jsonOk(
    '[{"appName":"container","version":"1.6.0","buildType":"release","commit":"unspecified"},'
    '{"appName":"container-apiserver","version":"1.6.0","buildType":"release","commit":"unspecified"}]',
  );

  BridgeCommandResult statusResult = _jsonOk(
    '{"status":"running","paths":{"appRoot":"/app/root/","installRoot":"/install/root/"},'
    '"resources":{"containersRunning":1,"containersTotal":2,"images":3}}',
  );

  BridgeCommandResult startResult = _ok;
  BridgeCommandResult stopResult = _ok;
  BridgeCommandResult kernelSetResult = _ok;

  bool kernelPresent = true;
  final Map<String, bool> kernelsByAppRoot = <String, bool>{};

  /// Scripted ping outcomes, consumed one per call; repeats the last entry
  /// when exhausted. Defaults to a single success.
  List<BridgePingResult> pingScript = [
    const BridgePingResult.ok(apiServerVersion: '1.6.0', appRoot: '/app/root/'),
  ];

  /// Recorded calls as "method arg1 arg2 ..." strings.
  final List<String> calls = <String>[];

  static const _ok = BridgeCommandResult(exitCode: 0, stdout: '', stderr: '');

  static BridgeCommandResult _jsonOk(String stdout) =>
      BridgeCommandResult(exitCode: 0, stdout: stdout, stderr: '');

  @override
  Future<String?> locateBinary({String? customPath}) async {
    calls.add('locateBinary${customPath != null ? ' custom=$customPath' : ''}');
    return customPath ?? binaryPath;
  }

  @override
  Future<BridgeCommandResult> systemVersion() async {
    calls.add('systemVersion');
    return versionResult;
  }

  @override
  Future<BridgeCommandResult> systemStatus() async {
    calls.add('systemStatus');
    return statusResult;
  }

  @override
  Future<BridgeCommandResult> systemStart({
    required bool installKernel,
    String? appRoot,
  }) async {
    calls.add(
      'systemStart installKernel=$installKernel${appRoot == null ? '' : ' appRoot=$appRoot'}',
    );
    return startResult;
  }

  @override
  Future<BridgeCommandResult> systemStop() async {
    calls.add('systemStop');
    return stopResult;
  }

  @override
  Future<BridgeCommandResult> kernelSetRecommended({bool force = false}) async {
    calls.add('kernelSetRecommended force=$force');
    return kernelSetResult;
  }

  @override
  Future<bool> kernelInstalled({String? appRoot}) async {
    calls.add('kernelInstalled');
    return kernelsByAppRoot[appRoot] ?? kernelPresent;
  }

  @override
  Future<BridgePingResult> ping() async {
    calls.add('ping');
    if (pingScript.length > 1) return pingScript.removeAt(0);
    return pingScript.first;
  }

  BridgeCommandResult cliRunResult = _ok;
  final List<Map<String, Object?>> cliRunRequests = <Map<String, Object?>>[];
  final List<List<String>> cliStartRequests = <List<String>>[];
  final List<FakeBridgeCliProcess> cliProcessScript = <FakeBridgeCliProcess>[];
  final List<FakeBridgeCliProcess> cliStartedProcesses =
      <FakeBridgeCliProcess>[];

  @override
  Future<BridgeCommandResult> cliRun(
    List<String> arguments, {
    Duration? timeout,
  }) async {
    calls.add('cliRun ${arguments.join(' ')}');
    cliRunRequests.add(<String, Object?>{
      'arguments': List<String>.unmodifiable(arguments),
      'timeout': timeout,
    });
    return cliRunResult;
  }

  @override
  BridgeCliProcess cliStart(List<String> arguments) {
    calls.add('cliStart ${arguments.join(' ')}');
    cliStartRequests.add(List<String>.unmodifiable(arguments));
    final process = cliProcessScript.isNotEmpty
        ? cliProcessScript.removeAt(0)
        : (FakeBridgeCliProcess()..finish(0));
    cliStartedProcesses.add(process);
    return process;
  }

  // -- container domain (T2a) ---------------------------------------------

  /// Whether [containerList] throws ("connection invalid") before answering.
  bool containerListThrows = false;

  /// Scripted container snapshot lists consumed one per [containerList]
  /// call; when empty, the current [containers] value is returned instead.
  /// Use this to script poll-after-poll state changes.
  final List<List<Map<String, Object?>>> containerListResponses =
      <List<Map<String, Object?>>>[];

  /// Current container set as snapshot maps (mutate between polls to
  /// simulate runtime-side changes).
  List<Map<String, Object?>> containers = <Map<String, Object?>>[];

  /// Inspect failures keyed by container id (thrown as [BridgeCallException]).
  final Map<String, String> inspectFailures = <String, String>{};

  /// Stats failures keyed by container id.
  final Map<String, String> statsFailures = <String, String>{};

  /// Scripted stats payloads keyed by container id (falls back to a
  /// plausible running snapshot).
  final Map<String, Map<String, Object?>> statsResponses =
      <String, Map<String, Object?>>{};

  /// Scripted log event sequences keyed by container id.
  final Map<String, List<BridgeLogEvent>> logResponses =
      <String, List<BridgeLogEvent>>{};

  @override
  Future<List<Map<String, Object?>>> containerList() async {
    calls.add('containerList');
    if (containerListThrows) {
      throw const BridgeCallException('connection invalid');
    }
    return containerListResponses.isNotEmpty
        ? containerListResponses.removeAt(0)
        : containers;
  }

  @override
  Future<Map<String, Object?>> containerInspect(String id) async {
    calls.add('containerInspect:$id');
    final failure = inspectFailures[id];
    if (failure != null) throw BridgeCallException(failure);
    Map<String, Object?>? match;
    for (final snapshot in containers) {
      if (_snapshotId(snapshot) == id) {
        match = snapshot;
        break;
      }
    }
    if (match == null) {
      throw BridgeCallException('container "$id" not found');
    }
    return match;
  }

  @override
  Future<Map<String, Object?>> containerStats(String id) async {
    calls.add('containerStats:$id');
    final failure = statsFailures[id];
    if (failure != null) throw BridgeCallException(failure);
    return statsResponses[id] ??
        <String, Object?>{
          'id': id,
          'memoryUsageBytes': 64 * 1024 * 1024,
          'memoryLimitBytes': 512 * 1024 * 1024,
          'cpuUsageUsec': 250000,
          'networkRxBytes': 1024,
          'networkTxBytes': 2048,
          'numProcesses': 3,
        };
  }

  @override
  Stream<BridgeLogEvent> containerLogs(String id) {
    calls.add('containerLogs:$id');
    final events = logResponses[id] ?? const <BridgeLogEvent>[];
    return Stream.fromIterable(events);
  }

  /// Scripted write failures keyed as `operation:id` (for example
  /// `start:web`). Optional gates hold a write after recording its call.
  final Map<String, String> writeFailures = <String, String>{};
  Completer<void>? createGate;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  Completer<void>? deleteGate;
  Completer<void>? killGate;

  final List<Map<String, Object?>> createRequests = <Map<String, Object?>>[];
  final List<Map<String, Object?>> killRequests = <Map<String, Object?>>[];
  final List<Map<String, Object?>> execRequests = <Map<String, Object?>>[];
  BridgeExecResult execResult = const BridgeExecResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );
  Completer<void>? execGate;
  int startCalls = 0;
  int stopCalls = 0;
  int deleteCalls = 0;
  bool stoppedGracefully = true;

  @override
  Future<void> containerCreate({
    required String id,
    required String image,
    List<String> command = const [],
    List<String> env = const [],
    List<String> ports = const [],
    String? network,
    List<Map<String, Object?>> mounts = const [],
    Map<String, String> labels = const {},
  }) async {
    calls.add('containerCreate:$id');
    createRequests.add(<String, Object?>{
      'id': id,
      'image': image,
      'command': command,
      'env': env,
      'ports': ports,
      'network': network,
      'mounts': mounts,
      'labels': labels,
    });
    _throwWriteFailure('create', id);
    if (createGate != null) await createGate!.future;
    if (_indexOf(id) >= 0) {
      throw BridgeCallException('container "$id" already exists');
    }
    containers.add(<String, Object?>{
      'status': 'stopped',
      'configuration': <String, Object?>{
        'id': id,
        'image': <String, Object?>{'reference': image},
        'labels': labels,
        'mounts': mounts,
        'initProcess': <String, Object?>{
          'arguments': command,
          'environment': env,
        },
      },
      'networks': network == null
          ? <Object?>[]
          : <Object?>[
              <String, Object?>{'network': network},
            ],
      'ports': <Object?>[],
    });
  }

  @override
  Future<void> containerStart(String id) async {
    calls.add('containerStart:$id');
    startCalls++;
    _throwWriteFailure('start', id);
    if (startGate != null) await startGate!.future;
    _setContainerState(id, 'running');
  }

  @override
  Future<bool> containerStop(String id, {int timeoutSeconds = 5}) async {
    calls.add('containerStop:$id timeout=$timeoutSeconds');
    stopCalls++;
    _throwWriteFailure('stop', id);
    if (stopGate != null) await stopGate!.future;
    _setContainerState(id, 'stopped');
    return stoppedGracefully;
  }

  @override
  Future<void> containerDelete(String id, {bool force = false}) async {
    calls.add('containerDelete:$id force=$force');
    deleteCalls++;
    _throwWriteFailure('delete', id);
    if (deleteGate != null) await deleteGate!.future;
    final index = _indexOf(id);
    if (index < 0) {
      throw BridgeCallException('container "$id" not found');
    }
    final status = containers[index]['status'] as String? ?? 'unknown';
    if (status == 'stopping') {
      throw BridgeCallException('container "$id" is stopping');
    }
    if (status == 'running' && !force) {
      throw BridgeCallException('container "$id" is running');
    }
    containers.removeAt(index);
  }

  @override
  Future<String> containerKill(String id, {String signal = 'KILL'}) async {
    calls.add('containerKill:$id signal=$signal');
    killRequests.add(<String, Object?>{'id': id, 'signal': signal});
    _throwWriteFailure('kill', id);
    if (killGate != null) await killGate!.future;
    if (_indexOf(id) < 0) {
      throw BridgeCallException('container "$id" not found');
    }
    if (signal == 'KILL') {
      _setContainerState(id, 'stopped');
    }
    return containers[_indexOf(id)]['status'] as String? ?? 'unknown';
  }

  @override
  Future<BridgeExecResult> containerExec({
    required String id,
    required List<String> command,
    List<String> env = const [],
    String? workdir,
    String? user,
    int timeoutSeconds = 60,
  }) async {
    calls.add('containerExec:$id');
    execRequests.add(<String, Object?>{
      'id': id,
      'command': command,
      'env': env,
      'workdir': workdir,
      'user': user,
      'timeoutSeconds': timeoutSeconds,
    });
    _throwWriteFailure('exec', id);
    if (execGate != null) await execGate!.future;
    return execResult;
  }

  void _throwWriteFailure(String operation, String id) {
    final failure = writeFailures['$operation:$id'];
    if (failure != null) throw BridgeCallException(failure);
  }

  int _indexOf(String id) {
    return containers.indexWhere((snapshot) => _snapshotId(snapshot) == id);
  }

  void _setContainerState(String id, String state) {
    final index = _indexOf(id);
    if (index < 0) {
      throw BridgeCallException('container "$id" not found');
    }
    final previous = containers[index];
    if (previous['status'] == state) return;
    containers[index] = <String, Object?>{
      ...previous,
      'status': state,
      'startedAt': state == 'running' ? DateTime.now().toIso8601String() : null,
    };
  }

  // -- network domain (T6) ---------------------------------------------------

  /// Scripted `container network ls --format json` result.
  BridgeCommandResult networkListResult = _jsonOk('[]');

  /// Scripted inspect results keyed by network id; missing id → exitCode 1
  /// with a "not found"-style stderr (mirrors CLI behaviour).
  final Map<String, BridgeCommandResult> networkInspectResults =
      <String, BridgeCommandResult>{};

  @override
  Future<BridgeCommandResult> networkList() async {
    calls.add('networkList');
    return networkListResult;
  }

  @override
  Future<BridgeCommandResult> networkInspect(String id) async {
    calls.add('networkInspect:$id');
    return networkInspectResults[id] ??
        BridgeCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Error: network "$id" not found',
        );
  }

  // -- compose domain (T6) ---------------------------------------------------

  /// Scripted `container compose --help` probe. Defaults to "installed"
  /// (exit 0, up/down listed); set to a failure to simulate a missing plugin.
  BridgeCommandResult composeHelpResult = _jsonOk(
    'OVERVIEW: Bring a set of services up and down from a compose file.\n'
    'SUBCOMMANDS:\n  up\n  down\n',
  );

  /// Scripted compose run results consumed one per [composeRun] call;
  /// repeats the last entry when exhausted.
  List<BridgeCommandResult> composeRunScript = <BridgeCommandResult>[_ok];

  @override
  Future<BridgeCommandResult> composeHelp() async {
    calls.add('composeHelp');
    return composeHelpResult;
  }

  @override
  Future<BridgeCommandResult> composeRun(
    List<String> arguments, {
    Duration? timeout,
  }) async {
    calls.add('composeRun ${arguments.join(' ')}');
    if (composeRunScript.length > 1) return composeRunScript.removeAt(0);
    return composeRunScript.first;
  }

  // -- image domain (T5) -----------------------------------------------------

  /// Current image set as ImageDescription maps (mutate between refreshes
  /// to simulate runtime-side changes).
  List<Map<String, Object?>> images = <Map<String, Object?>>[];

  /// Whether [imageList] throws ("connection invalid") before answering.
  bool imageListThrows = false;

  /// Scripted inspect payloads keyed by reference.
  final Map<String, Map<String, Object?>> imageInspectResponses =
      <String, Map<String, Object?>>{};

  /// Inspect failures keyed by reference (thrown as [BridgeCallException]).
  final Map<String, String> imageInspectFailures = <String, String>{};

  /// Delete failures keyed by reference (thrown as [BridgeCallException]).
  final Map<String, String> imageDeleteFailures = <String, String>{};

  /// Recorded deleted references, in order.
  final List<String> deletedImages = <String>[];

  /// Scripted pull result (ImageDescription map); [pullFailure] (when set)
  /// is thrown as [BridgeCallException] instead. When [pullHangs] is true
  /// the call only resolves after [imagePullCancel] (returns cancelled).
  Map<String, Object?> pullResult = <String, Object?>{
    'reference': 'docker.io/library/alpine:3.19',
    'digest': 'sha256:${'a' * 64}',
    'mediaType': 'application/vnd.oci.image.index.v1+json',
    'sizeBytes': 4096,
  };
  String? pullFailure;
  bool pullHangs = false;

  /// When set, [imagePull] waits for this completer before resolving with
  /// [pullResult]. Tests use it to emit progress events while the pull is
  /// still in flight (an immediate completion would cancel the service's
  /// event subscription before broadcast events are delivered).
  Completer<void>? pullBlocker;

  /// Recorded pulls as "pullId reference platform?" strings.
  final List<String> pullCalls = <String>[];

  /// Recorded cancel calls.
  final List<String> pullCancelCalls = <String>[];

  /// Gates for [pullHangs]: imagePull awaits, imagePullCancel completes.
  final Map<String, Completer<void>> _hangGates = <String, Completer<void>>{};

  /// Test-controlled broadcast of pull progress events.
  final StreamController<BridgeImagePullEvent> pullEventsController =
      StreamController<BridgeImagePullEvent>.broadcast();

  @override
  Future<List<Map<String, Object?>>> imageList() async {
    calls.add('imageList');
    if (imageListThrows) {
      throw const BridgeCallException('connection invalid');
    }
    return images;
  }

  @override
  Future<Map<String, Object?>> imageInspect(String reference) async {
    calls.add('imageInspect:$reference');
    final failure = imageInspectFailures[reference];
    if (failure != null) throw BridgeCallException(failure);
    final response = imageInspectResponses[reference];
    if (response == null) {
      throw BridgeCallException('image with reference $reference not found');
    }
    return response;
  }

  @override
  Future<void> imageDelete(String reference) async {
    calls.add('imageDelete:$reference');
    final failure = imageDeleteFailures[reference];
    if (failure != null) throw BridgeCallException(failure);
    deletedImages.add(reference);
    images.removeWhere((image) => image['reference'] == reference);
  }

  @override
  Future<Map<String, Object?>> imagePull({
    required String pullId,
    required String reference,
    String? platform,
  }) async {
    calls.add('imagePull:$pullId:$reference:${platform ?? '-'}');
    pullCalls.add('$pullId $reference ${platform ?? '-'}');
    final failure = pullFailure;
    if (failure != null) throw BridgeCallException(failure);
    if (pullHangs) {
      // Resolve only when the test cancels this pull. Completer-based gate
      // (microtask-driven): a `Future.delayed` poll loop is unreliable
      // inside widget tests' fake-async zone.
      final gate = Completer<void>();
      _hangGates[pullId] = gate;
      await gate.future;
      _hangGates.remove(pullId);
      return <String, Object?>{'reference': reference, 'cancelled': true};
    }
    await pullBlocker?.future;
    final result = Map<String, Object?>.of(pullResult);
    result['reference'] = reference;
    images.add(Map<String, Object?>.of(result));
    return result;
  }

  @override
  Future<void> imagePullCancel(String pullId) async {
    calls.add('imagePullCancel:$pullId');
    pullCancelCalls.add(pullId);
    _hangGates[pullId]?.complete();
  }

  @override
  Stream<BridgeImagePullEvent> imagePullEvents() => pullEventsController.stream;

  static String? _snapshotId(Map<String, Object?> snapshot) {
    final config = snapshot['configuration'];
    if (config is Map) return config['id'] as String?;
    return snapshot['id'] as String?;
  }
}

/// Scriptable generic CLI process. Single-subscription controllers retain
/// lines emitted before listeners attach, matching the method-channel adapter.
class FakeBridgeCliProcess implements BridgeCliProcess {
  FakeBridgeCliProcess({this.autoFinishOnTerminate = true});

  final bool autoFinishOnTerminate;
  final StreamController<String> _stdout = StreamController<String>();
  final StreamController<String> _stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();
  bool _finished = false;
  int terminateCalls = 0;

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  void addStdoutLine(String line) {
    if (!_finished) _stdout.add(line);
  }

  void addStderrLine(String line) {
    if (!_finished) _stderr.add(line);
  }

  void finish(int exitCode) {
    if (_finished) return;
    _finished = true;
    _exit.complete(exitCode);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  @override
  Future<void> terminate() async {
    terminateCalls += 1;
    if (autoFinishOnTerminate) finish(143);
  }
}
