/// Scriptable fake of [ContainerBridge] for tests and no-runtime development.
///
/// Each getter returns the scripted value; CLI calls record their arguments
/// in [calls] so tests can assert e.g. that system start always carries an
/// explicit kernel-install flag.
library;

import 'dart:async';

import 'container_bridge.dart';

class FakeContainerBridge implements ContainerBridge {
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

  /// Scripted ping outcomes, consumed one per call; repeats the last entry
  /// when exhausted. Defaults to a single success.
  List<BridgePingResult> pingScript = [
    const BridgePingResult.ok(apiServerVersion: '1.6.0'),
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
  Future<BridgeCommandResult> systemStart({required bool installKernel}) async {
    calls.add('systemStart installKernel=$installKernel');
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
  Future<bool> kernelInstalled() async {
    calls.add('kernelInstalled');
    return kernelPresent;
  }

  @override
  Future<BridgePingResult> ping() async {
    calls.add('ping');
    if (pingScript.length > 1) return pingScript.removeAt(0);
    return pingScript.first;
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
