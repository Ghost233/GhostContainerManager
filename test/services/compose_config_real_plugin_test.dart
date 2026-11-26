import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/docker_container_bridge.dart';
import 'package:ghost_container_manager/services/compose_config_validator.dart';

void main() {
  final docker = Platform.environment['GCM_COMPOSE_TEST_BINARY'];
  test(
    'real Compose validates with an intentionally unavailable Docker socket',
    () async {
      final stage = await Directory.systemTemp.createTemp(
        'gcm-compose-daemon-free-',
      );
      try {
        final path = await stage.resolveSymbolicLinks();
        final input = File('$path/compose.yaml');
        final sock = '$path/intentionally-inaccessible.sock';
        await File('$path/.env').writeAsString('GCM_LOCAL_CANARY=do-not-read');
        await input.writeAsString(
          '''
services:
  sample:
    image: alpine:3.20
    read_only: true
    network_mode: none
    pull_policy: never
    environment:
      GCM_LOCAL_CANARY: CANARY_PLACEHOLDER
    volumes:
      - type: bind
        source: ./synthetic-source
        target: /data
        read_only: true
'''
              .replaceFirst('CANARY_PLACEHOLDER', r'${GCM_LOCAL_CANARY}'),
        );
        final bridge = DockerContainerBridge(
          processStarter: (args) => Process.start(
            docker!,
            ['--host', 'unix://$sock', ...args],
            environment: {
              'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
            },
            includeParentEnvironment: false,
          ),
        );
        final validator = ComposeConfigValidator(bridge);
        expect(await validator.validate(input.path), {'valid': true});
        final result = await validator.validate(input.path, summary: true);
        expect(result, {
          'valid': true,
          'services': [
            {
              'service': 'sample',
              'readOnlyRoot': true,
              'networkDisabled': true,
              'neverPull': true,
              'readOnlyBindCount': 1,
              'writableBindCount': 0,
            },
          ],
        });
        expect(await File(sock).exists(), isFalse);
      } finally {
        await stage.delete(recursive: true);
      }
    },
    skip: docker == null
        ? 'Set GCM_COMPOSE_TEST_BINARY to a local Docker CLI.'
        : false,
  );
}
