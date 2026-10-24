import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';

void main() {
  group('FakeContainerBridge generic cli', () {
    test('cliRun records arguments and returns the scripted result', () async {
      final fake = FakeContainerBridge()
        ..cliRunResult = const BridgeCommandResult(
          exitCode: 9,
          stdout: 'out',
          stderr: 'err',
          timedOut: true,
        );

      final result = await fake.cliRun([
        'compose',
        'config',
      ], timeout: const Duration(seconds: 3));

      expect(fake.cliRunRequests.single, {
        'arguments': ['compose', 'config'],
        'timeout': const Duration(seconds: 3),
      });
      expect(result.exitCode, 9);
      expect(result.timedOut, isTrue);
    });

    test(
      'cliStart returns the scripted process and records arguments',
      () async {
        final scripted = FakeBridgeCliProcess();
        final fake = FakeContainerBridge()..cliProcessScript.add(scripted);

        final process = fake.cliStart(['compose', 'up', '-d']);
        final stdout = process.stdoutLines.toList();
        final stderr = process.stderrLines.toList();
        scripted
          ..addStdoutLine('ready')
          ..addStderrLine('warning')
          ..addStdoutLine('done')
          ..finish(0);

        expect(identical(process, scripted), isTrue);
        expect(fake.cliStartRequests.single, ['compose', 'up', '-d']);
        expect(await stdout, ['ready', 'done']);
        expect(await stderr, ['warning']);
        expect(await process.exitCode, 0);
      },
    );

    test('fake terminate is observable and completes the process', () async {
      final scripted = FakeBridgeCliProcess();
      final fake = FakeContainerBridge()..cliProcessScript.add(scripted);
      final process = fake.cliStart(['compose', 'up']);

      await process.terminate();

      expect(scripted.terminateCalls, 1);
      expect(await process.exitCode, 143);
    });
  });
}
