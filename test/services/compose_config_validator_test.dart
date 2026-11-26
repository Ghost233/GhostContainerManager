import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/compose_config_validator.dart';
import 'package:ghost_container_manager/services/errors.dart';

void main() {
  late Directory temp;
  late FakeContainerBridge bridge;
  late ComposeConfigValidator validator;
  late File input;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gcm-compose-test-');
    final canonical = await temp.resolveSymbolicLinks();
    input = File('$canonical/compose.yaml');
    bridge = FakeContainerBridge();
    validator = ComposeConfigValidator(bridge);
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'validate once with fixed flags; does not inspect or start runtime',
    () async {
      await input.writeAsString('services: {sample: {image: alpine}}');
      expect(await validator.validate(input.path), {'valid': true});
      expect(bridge.calls, hasLength(1));
      expect(
        bridge.calls.single,
        contains('config --no-interpolate --no-env-resolution --quiet'),
      );
      expect(bridge.calls.single, contains('--env-file /dev/null'));
      expect(bridge.calls.single, isNot(contains(input.path)));
    },
  );

  test(
    'summary excludes raw values and reports only isolation fields',
    () async {
      await input.writeAsString('services: {sample: {image: alpine}}');
      bridge.composeRunScript = [
        const BridgeCommandResult(
          exitCode: 0,
          stdout:
              '{"services":{"sample":{"read_only":true,"network_mode":"none","pull_policy":"never",'
              '"environment":{"PASSWORD":"sample-should-not-leave"},"volumes":[{"type":"bind","read_only":true,"source":"/hidden"},{"type":"bind"}]}}}',
          stderr: '',
        ),
      ];
      final value = await validator.validate(input.path, summary: true);
      expect(value, {
        'valid': true,
        'services': [
          {
            'service': 'sample',
            'readOnlyRoot': true,
            'networkDisabled': true,
            'neverPull': true,
            'readOnlyBindCount': 1,
            'writableBindCount': 1,
          },
        ],
      });
      expect(value.toString(), isNot(contains('sample-should-not-leave')));
    },
  );

  test(
    'file references and invalid YAML fail before invoking Compose',
    () async {
      for (final text in [
        'include: [https://example.invalid/config.yaml]\nservices: {sample: {image: alpine}}',
        'services: {sample: {env_file: ../outside}}',
        'services: {sample: {extends: {file: /outside.yaml}}}',
        'services: {sample: {label_file: /outside.txt}}',
        'services: {sample: [',
      ]) {
        await input.writeAsString(text);
        await expectLater(
          validator.validate(input.path),
          throwsA(isA<GcmException>()),
        );
      }
      expect(bridge.calls, isEmpty);
    },
  );

  test(
    'never expose Compose stderr on either validation or summary error',
    () async {
      await input.writeAsString('services: {sample: {image: alpine}}');
      bridge.composeRunScript = [
        const BridgeCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'sample-hidden-value',
        ),
      ];
      await expectLater(
        validator.validate(input.path, summary: true),
        throwsA(
          isA<GcmException>().having(
            (value) => value.toString(),
            'wire message',
            isNot(contains('sample-hidden-value')),
          ),
        ),
      );
    },
  );

  test('rejects symlink and relative file rather than reading it', () async {
    await input.writeAsString('services: {sample: {image: alpine}}');
    final link = Link('${input.parent.path}/linked.yaml');
    await link.create(input.path);
    await expectLater(
      validator.validate(link.path),
      throwsA(isA<GcmException>()),
    );
    await expectLater(
      validator.validate('compose.yaml'),
      throwsA(isA<GcmException>()),
    );
    expect(bridge.calls, isEmpty);
  });
}
