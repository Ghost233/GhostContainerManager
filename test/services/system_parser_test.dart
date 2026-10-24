import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/system_parser.dart';

// Real payload captured on container CLI 1.5.0 (issue #16 reconnaissance).
const versionJson150 =
    '[{"appName":"container","buildType":"release","commit":"unspecified","version":"1.5.0"},'
    '{"appName":"container-apiserver","buildType":"release","commit":"unspecified","version":"1.5.0"}]';

const statusJson =
    '{"client":{"appName":"container","build":"release","commit":"unspecified","version":"1.5.0"},'
    '"host":{"architecture":"arm64","cpus":18},'
    '"paths":{"appRoot":"/Users/x/Library/Application Support/com.apple.container/",'
    '"installRoot":"/opt/homebrew/Cellar/container/1.5.0/"},'
    '"resources":{"containersRunning":12,"containersTotal":30,"images":138},'
    '"server":{"appName":"container-apiserver","version":"1.5.0"},'
    '"status":"running"}';

void main() {
  group('RuntimeVersion', () {
    test('parses and compares', () {
      final v = RuntimeVersion.parse('1.6.0');
      expect(v.major, 1);
      expect(v.minor, 6);
      expect(v.patch, 0);
      expect(RuntimeVersion.parse('1.5.0') < v, isTrue);
      expect(RuntimeVersion.parse('1.6.1') >= v, isTrue);
      expect(RuntimeVersion.parse('2.0.0') >= v, isTrue);
    });

    test('rejects malformed versions', () {
      expect(() => RuntimeVersion.parse('abc'), throwsFormatException);
      expect(() => RuntimeVersion.parse('1.2'), throwsFormatException);
    });
  });

  group('parseSystemVersions', () {
    test('parses real 1.5.0 payload', () {
      final versions = parseSystemVersions(versionJson150);
      expect(versions.cli.toString(), '1.5.0');
      expect(versions.apiServer.toString(), '1.5.0');
      expect(versions.skewed, isFalse);
    });

    test('detects CLI/apiserver skew', () {
      final versions = parseSystemVersions(
        '[{"appName":"container","version":"1.6.0"},'
        '{"appName":"container-apiserver","version":"1.5.0"}]',
      );
      expect(versions.skewed, isTrue);
    });

    test('tolerates missing apiserver entry', () {
      final versions = parseSystemVersions(
        '[{"appName":"container","version":"1.6.0"}]',
      );
      expect(versions.apiServer, isNull);
      expect(versions.skewed, isFalse);
    });

    test('rejects malformed payloads', () {
      expect(() => parseSystemVersions('not json'), throwsFormatException);
      expect(() => parseSystemVersions('{"a":1}'), throwsFormatException);
      expect(() => parseSystemVersions('[]'), throwsFormatException);
    });
  });

  group('parseSystemStatus', () {
    test('parses real running payload', () {
      final data = parseSystemStatus(statusJson);
      expect(data.running, isTrue);
      expect(data.appRoot, contains('com.apple.container'));
      expect(data.installRoot, contains('Cellar'));
      expect(data.resources!.containersRunning, 12);
      expect(data.resources!.containersTotal, 30);
      expect(data.resources!.images, 138);
    });

    test('rejects malformed payloads', () {
      expect(() => parseSystemStatus('nope'), throwsFormatException);
      expect(() => parseSystemStatus('[1]'), throwsFormatException);
    });
  });

  group('mapBridgeFailure', () {
    test('connection invalid → RUNTIME_UNAVAILABLE', () {
      final e = mapBridgeFailure(
        'XPC connection invalid',
        operation: 'system stop',
      );
      expect(e.code, GcmErrorCode.runtimeUnavailable);
    });

    test('failed to decode + health check → VERSION_MISMATCH', () {
      final e = mapBridgeFailure(
        'failed to decode apiServerVersion in health check',
        operation: 'ping',
      );
      expect(e.code, GcmErrorCode.versionMismatch);
    });

    test('readLine stall → INTERNAL with kernel-flag hint', () {
      final e = mapBridgeFailure(
        'failed to read user input',
        operation: 'system start',
      );
      expect(e.code, GcmErrorCode.internal);
      expect(e.hint, contains('kernel-install'));
    });

    test('timeout → TIMEOUT', () {
      final e = mapBridgeFailure('', operation: 'system start', timedOut: true);
      expect(e.code, GcmErrorCode.timeout);
    });

    test('permission → PERMISSION_DENIED', () {
      final e = mapBridgeFailure('permission denied', operation: 'op');
      expect(e.code, GcmErrorCode.permissionDenied);
    });

    test('fallback → INTERNAL', () {
      final e = mapBridgeFailure('something odd', operation: 'op');
      expect(e.code, GcmErrorCode.internal);
    });

    test('wire payload shape matches mcp-tools.md §5', () {
      final wire = const GcmException(
        GcmErrorCode.internal,
        'm',
        hint: 'h',
      ).toWire();
      final error = wire['error']! as Map<String, Object?>;
      expect(error['code'], 'INTERNAL');
      expect(error['message'], isNotEmpty);
      expect(error['hint'], 'h');
    });
  });
}
