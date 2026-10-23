import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';

import 'container_service_test.dart' show snapshotPayload;

void main() {
  late FakeContainerBridge bridge;
  late ContainerService containerService;
  late ComposeService service;

  ComposeService build({int? maxOutputBytes}) => ComposeService(
    bridge: bridge,
    containerService: containerService,
    maxOutputBytes: maxOutputBytes ?? ComposeService.defaultMaxOutputBytes,
  );

  setUp(() {
    bridge = FakeContainerBridge();
    containerService = ContainerService(bridge: bridge);
    service = build();
  });

  group('detect', () {
    test('default fake → installed (help lists up/down)', () async {
      final status = await service.detect();

      expect(status.installed, isTrue);
      expect(bridge.calls, contains('composeHelp'));
    });

    test('help failure → not installed with stderr detail', () async {
      bridge.composeHelpResult = const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error: unknown command "compose"',
      );

      final status = await service.detect();

      expect(status.installed, isFalse);
      expect(status.detail, contains('unknown command'));
    });
  });

  group('listProjects', () {
    test('aggregates by com.compose.project with service names', () async {
      bridge.containers = [
        snapshotPayload(
          id: 'shop-web',
          labels: const {
            'com.compose.project': 'shop',
            'com.compose.service': 'web',
          },
        ),
        snapshotPayload(
          id: 'shop-db',
          status: 'stopped',
          startedAt: null,
          labels: const {
            'com.compose.project': 'shop',
            'com.compose.service': 'db',
          },
        ),
        snapshotPayload(
          id: 'blog-web',
          labels: const {'com.compose.project': 'blog'},
        ),
        snapshotPayload(id: 'plain'), // no compose labels
      ];

      final projects = await service.listProjects();

      expect(projects, hasLength(2));
      final shop = projects.firstWhere((p) => p.name == 'shop');
      expect(shop.services, hasLength(2));
      expect(shop.runningCount, 1);
      expect(
        shop.services.map((s) => s.serviceName),
        containsAll(['web', 'db']),
      );
      expect(projects.firstWhere((p) => p.name == 'blog').runningCount, 1);
    });
  });

  group('up', () {
    test('relative file path → INVALID_ARGUMENT', () {
      // up() validates synchronously (non-async body) before returning.
      expect(
        () => service.up(file: 'compose.yaml'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('unknown pull policy → INVALID_ARGUMENT', () {
      expect(
        () => service.up(file: '/tmp/compose.yaml', pull: 'sometimes'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('happy path passes plugin arguments through', () async {
      bridge.composeRunScript = [
        const BridgeCommandResult(
          exitCode: 0,
          stdout: 'plan: would create 2 containers',
          stderr: '',
        ),
      ];

      final result = await service.up(
        file: '/tmp/compose.yaml',
        projectName: 'shop',
        dryRun: true,
      );

      expect(result.exitCode, 0);
      expect(result.output, contains('would create 2 containers'));
      expect(result.truncated, isFalse);
      expect(
        bridge.calls,
        contains(
          'composeRun up --file /tmp/compose.yaml --project-name shop '
          '--dry-run --pull missing',
        ),
      );
    });

    test('plugin missing → NOT_FOUND with install hint', () async {
      bridge.composeHelpResult = const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error: unknown command "compose"',
      );

      await expectLater(
        service.up(file: '/tmp/compose.yaml'),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.notFound)
              .having(
                (e) => e.hint,
                'hint',
                contains('/usr/local/libexec/container-plugins/'),
              ),
        ),
      );
    });

    test('output over maxOutputBytes is tail-truncated', () async {
      service = build(maxOutputBytes: 16);
      bridge.composeRunScript = [
        BridgeCommandResult(
          exitCode: 0,
          stdout: '0123456789abcdefghij-尾部',
          stderr: '',
        ),
      ];

      final result = await service.up(file: '/tmp/compose.yaml');

      expect(result.truncated, isTrue);
      expect(result.output, contains('截断'));
      expect(result.output, endsWith('尾部'));
    });
  });

  group('down', () {
    test('neither file nor projectName → INVALID_ARGUMENT', () {
      expect(
        () => service.down(),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('projectName + keepNetworks map to plugin arguments', () async {
      await service.down(projectName: 'shop', keepNetworks: true);

      expect(
        bridge.calls,
        contains('composeRun down --project-name shop --keep-networks'),
      );
    });
  });
}
