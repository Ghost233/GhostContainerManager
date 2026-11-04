// Opt-in only; not included in the normal test discovery tree. Run explicitly:
// GCM_REAL_DOCKER=1 GCM_DOCKER_HOST=unix:///absolute/socket \
//   GCM_DOCKER_IMAGE=<cached-image> flutter test test/support/real_docker_recovery.dart
// A shared daemon provides scoped-resource isolation, NOT an isolated runtime.
// Use a trusted cached image containing /bin/sleep. No pulls or pruning.
// Lost-response recovery remains pending without a terminality proof; this
// harness does not establish full issue #61 acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/container_runtime_identity.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/directory_container_recovery.dart';
import 'package:ghost_container_manager/services/directory_registry.dart';

const _marker = 'com.ghost233.gcm.integration-test';
final _idPattern = RegExp(r'^[0-9a-f]{64}$');

class _Harness {
  _Harness(this.host, this.image, this.marker, this.executable);
  final String executable;
  final String host;
  final String image;
  final String marker;
  final captured = <String, String>{}; // Exact container ID -> operation ID.
  final knownOperations = <String>{};
  String? replacementName;
  String? replacementOperation;
  var loseNextCreateResponse = false;
  var createCount = 0;
  var indeterminateCreate = false;

  Future<BridgeCommandResult> command(
    List<String> args,
    Duration timeout,
  ) async {
    final environment = Map<String, String>.from(Platform.environment)
      ..remove('DOCKER_CONTEXT')
      ..remove('DOCKER_HOST')
      ..remove('DOCKER_TLS_VERIFY')
      ..remove('DOCKER_CERT_PATH');
    final process = await Process.start(
      executable,
      ['--host', host, ...args],
      environment: environment,
      includeParentEnvironment: false,
    );
    await process.stdin.close();
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
    });
    final code = await process.exitCode;
    timer.cancel();
    return BridgeCommandResult(
      exitCode: code,
      stdout: await out,
      stderr: await err,
      timedOut: timedOut,
    );
  }

  Future<BridgeCommandResult> checked(List<String> args) async {
    final result = await command(args, const Duration(seconds: 30));
    if (!result.ok) {
      throw StateError('docker $args failed: ${result.combinedOutput}');
    }
    return result;
  }

  Future<Map<String, Set<String>>> inventory() async {
    final resources = <String, List<String>>{
      'containers': ['container', 'ls', '--all', '--quiet', '--no-trunc'],
      'images': ['image', 'ls', '--all', '--quiet', '--no-trunc'],
      'networks': ['network', 'ls', '--quiet', '--no-trunc'],
      'volumes': ['volume', 'ls', '--quiet'],
    };
    final result = <String, Set<String>>{};
    for (final entry in resources.entries) {
      final output = await checked(entry.value);
      result[entry.key] = output.stdout
          .split(RegExp(r'\s+'))
          .where((v) => v.isNotEmpty)
          .toSet();
    }
    return result;
  }

  Future<Map> inspect(String id) async {
    if (!_idPattern.hasMatch(id)) throw StateError('Not a full ID: $id');
    final result = await checked(['container', 'inspect', id]);
    final data = jsonDecode(result.stdout);
    if (data is! List ||
        data.length != 1 ||
        data.single is! Map ||
        data.single['Id'] != id) {
      throw StateError('Invalid container inspection for $id');
    }
    return data.single as Map;
  }

  Future<void> removeCaptured(String id) async {
    final operation = captured[id];
    if (operation == null) throw StateError('Refusing uncaptured ID $id');
    final raw = await inspect(id);
    final labels = (raw['Config'] as Map)['Labels'] as Map;
    if (labels[_marker] != marker ||
        labels[ContainerRuntimeIdentityService.productLabel] != 'true' ||
        labels[ContainerRuntimeIdentityService.operationLabel] != operation) {
      throw StateError('Refusing cleanup: markers changed for $id');
    }
    await checked(['container', 'rm', '--force', id]);
    captured.remove(id);
  }

  Future<BridgeCommandResult> runner(
    List<String> args,
    Duration timeout,
  ) async {
    if (args.length < 2 || args.first != 'container') {
      throw StateError('Denied command: $args');
    }
    if (args[1] == 'create') {
      // Only the identity service's exact fixed form is accepted. No caller
      // options, mounts, ports, entrypoint overrides, or arbitrary commands.
      if (args.length != 14 ||
          args[2] != '--name' ||
          args[4] != '--label' ||
          args[5] != '${ContainerRuntimeIdentityService.productLabel}=true' ||
          args[6] != '--label' ||
          !args[7].startsWith(
            '${ContainerRuntimeIdentityService.operationLabel}=',
          ) ||
          args[8] != '--label' ||
          args[9] != '$_marker=$marker' ||
          args[10] != '--' ||
          args[11] != image ||
          args[12] != '/bin/sleep' ||
          args[13] != '300') {
        throw StateError('Denied create: $args');
      }
      final operation = args[7].substring(args[7].indexOf('=') + 1);
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(operation) ||
          (args[3] != 'gcm-$operation' &&
              !(operation == replacementOperation &&
                  args[3] == replacementName))) {
        throw StateError('Denied create identity');
      }
      createCount++;
      knownOperations.add(operation);
      final constrained = [
        ...args.take(10),
        '--pull=never',
        '--network=none',
        '--memory=64m',
        '--pids-limit=32',
        '--cpus=0.5',
        ...args.skip(10),
      ];
      final result = await command(constrained, timeout);
      final id = result.stdout.trim();
      if (result.ok && _idPattern.hasMatch(id)) {
        captured[id] = operation;
      } else {
        indeterminateCreate = true;
      }
      if (loseNextCreateResponse && result.ok && _idPattern.hasMatch(id)) {
        loseNextCreateResponse = false;
        // The real create succeeded and the ID was captured for cleanup; only
        // delivery to the service is simulated as lost.
        throw const BridgeCallException(
          'simulated lost create response after real CLI success',
        );
      }
      return result;
    }
    if (args.length == 5 &&
        args[1] == 'ls' &&
        args[2] == '--all' &&
        args[3] == '--quiet' &&
        args[4] == '--no-trunc') {
      final result = await command(args, timeout);
      if (!result.ok) return result;
      final ids = result.stdout
          .split(RegExp(r'\s+'))
          .where((id) => id.isNotEmpty);
      if (ids.any((id) => !_idPattern.hasMatch(id))) {
        throw StateError('Invalid container inventory');
      }
      return result;
    }
    if (args.length > 2 &&
        args[1] == 'inspect' &&
        args.skip(2).every(_idPattern.hasMatch)) {
      return command(args, timeout);
    }
    if (args[1] == 'ls' &&
        args.length == 7 &&
        args[2] == '--all' &&
        args[3] == '--quiet' &&
        args[4] == '--no-trunc' &&
        args[5] == '--filter' &&
        args[6].startsWith(
          'label=${ContainerRuntimeIdentityService.operationLabel}=',
        )) {
      final operation = args[6].split('=').last;
      if (!knownOperations.contains(operation)) {
        throw StateError('Denied unowned query');
      }
      return command(args, timeout);
    }
    if (args[1] == 'start' &&
        args.length == 3 &&
        captured.containsKey(args[2])) {
      final raw = await inspect(args[2]);
      final labels = (raw['Config'] as Map)['Labels'] as Map;
      if (labels[_marker] != marker ||
          labels[ContainerRuntimeIdentityService.productLabel] != 'true' ||
          labels[ContainerRuntimeIdentityService.operationLabel] !=
              captured[args[2]]) {
        throw StateError('Refusing start: markers changed for ${args[2]}');
      }
      return command(args, timeout);
    }
    throw StateError('Denied command: $args');
  }
}

void main() {
  final enabled = Platform.environment['GCM_REAL_DOCKER'] == '1';
  test(
    'real create, start, restart recovery, and same-name replacement',
    () async {
      final host = Platform.environment['GCM_DOCKER_HOST'] ?? '';
      final image = Platform.environment['GCM_DOCKER_IMAGE'] ?? '';
      final executable =
          Platform.environment['GCM_DOCKER_CLI'] ?? '/usr/local/bin/docker';
      if (!executable.startsWith('/') ||
          !Platform.isMacOS ||
          !host.startsWith('unix:///') ||
          host.contains('?') ||
          host.contains('#') ||
          image.isEmpty ||
          image.startsWith('-')) {
        throw StateError(
          'Require macOS, explicit local unix GCM_DOCKER_HOST and cached GCM_DOCKER_IMAGE',
        );
      }
      final random = Random.secure();
      final marker = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final h = _Harness(host, image, marker, executable);
      final temp = await Directory.systemTemp.createTemp('gcm-real-recovery-');
      final failures = <Object>[];
      Map<String, Set<String>>? before;
      try {
        final version = await h.checked([
          'version',
          '--format',
          '{{json .Server}}',
        ]);
        // Endpoint is captured explicitly; version and marker are useful evidence.
        stdout.writeln(
          'Docker endpoint: $host; server: ${version.stdout.trim()}; test marker: $marker',
        );
        stdout.writeln(
          'Shared daemon: scoped-resource isolation only, not an isolated runtime.',
        );
        before = await h.inventory();
        stdout.writeln(
          'Pre-test inventory (volume entries are names): $before',
        );
        final imageData = jsonDecode(
          (await h.checked(['image', 'inspect', image])).stdout,
        );
        if (imageData is! List ||
            imageData.length != 1 ||
            imageData.single is! Map) {
          throw StateError('Invalid image inspection');
        }
        final rawImage = imageData.single as Map;
        final imageId = rawImage['Id'];
        final config = rawImage['Config'];
        if (imageId is! String ||
            !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(imageId) ||
            config is! Map ||
            (config['Volumes'] != null &&
                (config['Volumes'] is! Map ||
                    (config['Volumes'] as Map).isNotEmpty)) ||
            (config['Entrypoint'] != null &&
                (config['Entrypoint'] is! List ||
                    (config['Entrypoint'] as List).isNotEmpty))) {
          throw StateError(
            'Image must have empty Volumes and Entrypoint and a full immutable ID',
          );
        }
        // Pin the inspected image ID so a retag cannot change the image used.
        final pinned = _Harness(host, imageId, marker, executable);
        final registryFile = File('${temp.path}/registry.json');
        final services = <ContainerService>[];
        DirectoryContainerRecovery service() {
          final owner = ContainerService(
            directoryRegistry: DirectoryRegistry(registryFile),
            bridge: DockerContainerBridge(runner: pinned.runner),
          );
          services.add(owner);
          return owner.directoryRecovery!;
        }

        try {
          final result = await service().create(
            directory: temp.path,
            businessName: 'integration',
            image: imageId,
            labels: {_marker: marker},
            arguments: ['/bin/sleep', '300'],
            start: true,
          );
          expect(result.status, DirectoryCreationStatus.registered);
          final original = result.containerId!;
          expect(pinned.captured.containsKey(original), isTrue);
          expect(
            (await DirectoryRegistry(registryFile).query(temp.path)),
            contains('container:$original'),
          );
          expect(
            ((await pinned.inspect(original))['State'] as Map)['Running'],
            isTrue,
          );
          expect(
            (await service().recover(result.operationId)).containerId,
            original,
          );
          pinned.loseNextCreateResponse = true;
          final lost = await service().create(
            directory: temp.path,
            businessName: 'lost',
            image: imageId,
            labels: {_marker: marker},
            arguments: ['/bin/sleep', '300'],
          );
          expect(lost.status, DirectoryCreationStatus.unknown);
          final lostId = pinned.captured.keys.singleWhere(
            (id) => id != original,
          );
          // The runner knows the CLI returned, but that knowledge is not
          // conveyed to the service as proof that its request is terminal.
          // It must not infer ownership from a single observed match.
          final recovered = await service().recover(lost.operationId);
          expect(recovered.status, DirectoryCreationStatus.unknown);
          expect(
            await DirectoryRegistry(registryFile).query(temp.path),
            isNot(contains('container:$lostId')),
          );
          expect(
            (await service().recover(lost.operationId)).status,
            DirectoryCreationStatus.unknown,
          );
          expect(
            await DirectoryRegistry(registryFile).query(temp.path),
            isNot(contains('container:$lostId')),
          );
          expect(pinned.createCount, 2);
          final name = (await pinned.inspect(original))['Name'] as String;
          await pinned.removeCaptured(original);
          // Reuse the exact runtime name with a different operation marker. This
          // replacement is test-owned, not a pre-existing user container.
          final replacementOperation = 'replacement-$marker';
          pinned.replacementName = name.substring(1);
          pinned.replacementOperation = replacementOperation;
          final replacement = await pinned.runner([
            'container',
            'create',
            '--name',
            name.substring(1),
            '--label',
            '${ContainerRuntimeIdentityService.productLabel}=true',
            '--label',
            '${ContainerRuntimeIdentityService.operationLabel}=$replacementOperation',
            '--label',
            '$_marker=$marker',
            '--',
            imageId,
            '/bin/sleep',
            '300',
          ], const Duration(seconds: 30));
          expect(replacement.ok, isTrue);
          final replacementId = replacement.stdout.trim();
          expect(replacementId, isNot(original));
          final after = await service().recover(result.operationId);
          expect(after.status, isNot(DirectoryCreationStatus.registered));
          expect(
            await DirectoryRegistry(registryFile).query(temp.path),
            isNot(contains('container:$replacementId')),
          );
          expect(
            ((await pinned.inspect(replacementId))['State'] as Map)['Running'],
            isFalse,
          );
        } finally {
          for (final owner in services) {
            try {
              await owner.dispose();
            } catch (error) {
              failures.add('service disposal: $error');
            }
          }
          for (final id in pinned.captured.keys.toList()) {
            try {
              await pinned.removeCaptured(id);
            } catch (error) {
              failures.add('cleanup $id: $error');
            }
          }
          if (pinned.indeterminateCreate) {
            failures.add(
              'A create result was indeterminate; inspect daemon manually. No discovery or automatic cleanup attempted.',
            );
          }
        }
      } catch (error, stack) {
        failures.insert(0, 'test failure: $error\n$stack');
      } finally {
        if (before != null) {
          try {
            final after = await h.inventory();
            stdout.writeln(
              'Post-test inventory (volume entries are names): $after',
            );
            for (final entry in before.entries) {
              final missing = entry.value.difference(after[entry.key]!);
              if (missing.isNotEmpty) {
                failures.add(
                  'Pre-existing ${entry.key} missing after test: $missing; concurrent external changes are possible',
                );
              }
            }
          } catch (error) {
            failures.add('post-test inventory failed: $error');
          }
        }
        try {
          await temp.delete(recursive: true);
        } catch (error) {
          failures.add('temporary directory cleanup: $error');
        }
        if (failures.isNotEmpty) throw StateError(failures.join('\n'));
      }
    },
    skip: enabled ? false : 'Set GCM_REAL_DOCKER=1 to opt in',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
