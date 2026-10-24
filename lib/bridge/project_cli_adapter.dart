import '../services/project_service.dart';
import 'container_bridge.dart';

/// Production [ProjectCli] adapter backed by the generic container CLI seam
/// ([ContainerBridge.cliRun]/[ContainerBridge.cliStart]).
///
/// Cancellation terminates the whole CLI process group natively (see
/// CliProcess.swift: kill(-pid, SIGTERM)).
class BridgeProjectCli implements ProjectCli {
  BridgeProjectCli(this._bridge);

  final ContainerBridge _bridge;

  @override
  Future<BridgeCommandResult> run(List<String> args, {Duration? timeout}) =>
      _bridge.cliRun(args, timeout: timeout);

  @override
  ProjectCliProcess start(List<String> args) =>
      _BridgeProjectCliProcess(_bridge.cliStart(args));
}

class _BridgeProjectCliProcess implements ProjectCliProcess {
  _BridgeProjectCliProcess(this._process);

  final BridgeCliProcess _process;

  @override
  Stream<String> get stdoutLines => _process.stdoutLines;

  @override
  Stream<String> get stderrLines => _process.stderrLines;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void terminate() {
    // Fire-and-forget mirrors the exec timeout semantics: the native side
    // terminates the process group; the exit code still resolves.
    _process.terminate();
  }
}
