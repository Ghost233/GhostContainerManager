/// Scriptable fake of [ContainerBridge] for tests and no-runtime development.
///
/// Each getter returns the scripted value; CLI calls record their arguments
/// in [calls] so tests can assert e.g. that system start always carries an
/// explicit kernel-install flag.
library;

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

  static String? _snapshotId(Map<String, Object?> snapshot) {
    final config = snapshot['configuration'];
    if (config is Map) return config['id'] as String?;
    return snapshot['id'] as String?;
  }
}
