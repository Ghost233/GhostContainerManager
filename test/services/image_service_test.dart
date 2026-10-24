import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/image_models.dart';
import 'package:ghost_container_manager/services/image_service.dart';

import 'container_service_test.dart' show snapshotPayload;

/// Service-layer evidence for issue #20 acceptance 3/5: addressing
/// validation (digest rejected with hint), dangling detection, the delete
/// in-use pre-check (clear CONFLICT naming the referencing containers),
/// and pull progress/cancel mapping — all against the fake bridge.
void main() {
  late FakeContainerBridge bridge;
  late ImageService service;

  Map<String, Object?> description(
    String reference, {
    String digest = 'sha256:abc123',
    int sizeBytes = 4096,
    String? createdAt = '2026-10-20T08:00:00Z',
  }) => <String, Object?>{
    'reference': reference,
    'digest': digest,
    'mediaType': 'application/vnd.oci.image.index.v1+json',
    'sizeBytes': sizeBytes,
    'createdAt': ?createdAt,
  };

  Map<String, Object?> inspection(String reference) => <String, Object?>{
    'reference': reference,
    'digest': 'sha256:def456',
    'sizeBytes': 7340032,
    'layers': 3,
    'platforms': <String>['linux/arm64', 'linux/amd64'],
    'config': <String, Object?>{
      'env': <String>['PATH=/usr/bin'],
      'entrypoint': <String>['/bin/sh'],
      'cmd': <String>['-c', 'serve'],
      'exposedPorts': <String>['80/tcp'],
      'labels': <String, String>{'org.opencontainers.image.title': 'demo'},
    },
  };

  setUp(() {
    bridge = FakeContainerBridge();
    service = ImageService(
      bridge: bridge,
      containerService: ContainerService(bridge: bridge),
    );
  });

  group('validateImageReference', () {
    test('accepts name:tag verbatim', () {
      final parsed = validateImageReference('docker.io/library/alpine:3.19');
      expect(parsed.reference, 'docker.io/library/alpine:3.19');
      expect(parsed.defaultedTag, isFalse);
    });

    test('defaults tag-less input to :latest', () {
      final parsed = validateImageReference('alpine');
      expect(parsed.reference, 'alpine:latest');
      expect(parsed.defaultedTag, isTrue);
    });

    test('treats a registry port as part of the name, not a tag', () {
      final parsed = validateImageReference('127.0.0.1:5056/myapp-go1');
      expect(parsed.reference, '127.0.0.1:5056/myapp-go1:latest');
    });

    test('rejects name@digest addressing with the #1962 hint', () {
      try {
        validateImageReference('alpine@sha256:${'a' * 64}');
        fail('expected GcmException');
      } on GcmException catch (e) {
        expect(e.code, GcmErrorCode.invalidArgument);
        expect(e.hint, contains('name:tag'));
        expect(e.hint, contains('1962'));
      }
    });

    test('rejects bare digests', () {
      expect(
        () => validateImageReference('sha256:${'a' * 64}'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('rejects empty input', () {
      expect(() => validateImageReference('  '), throwsA(isA<GcmException>()));
    });
  });

  group('mapImageFailure', () {
    test('marks every bridge failure branch as XPC-sourced', () {
      final cases = <(String, GcmErrorCode)>[
        ('connection invalid', GcmErrorCode.runtimeUnavailable),
        ('failed to decode response', GcmErrorCode.versionMismatch),
        ('permission denied', GcmErrorCode.permissionDenied),
        ('image not found', GcmErrorCode.notFound),
        ('image is in use', GcmErrorCode.conflict),
        ('unexpected response', GcmErrorCode.internal),
      ];

      for (final (message, code) in cases) {
        final error = mapImageFailure(
          BridgeCallException(message),
          operation: 'test',
        );
        expect(error.code, code, reason: message);
        expect(error.source, 'xpc', reason: message);
      }
    });
  });

  group('listImages', () {
    test('parses descriptions and flags dangling images', () async {
      bridge.images = [
        description('docker.io/library/alpine:3.19'),
        description('docker.io/library/alpine'), // untagged → dangling
      ];
      final images = await service.listImages();
      expect(images, hasLength(2));
      expect(images[0].isDangling, isFalse);
      expect(images[0].displayReference, 'docker.io/library/alpine:3.19');
      expect(images[1].isDangling, isTrue);
      expect(images[1].displayReference, 'docker.io/library/alpine:<none>');
      expect(images[0].createdAt, DateTime.parse('2026-10-20T08:00:00Z'));
    });

    test('maps XPC failures to RUNTIME_UNAVAILABLE', () {
      bridge.imageListThrows = true;
      expect(
        () => service.listImages(),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.runtimeUnavailable,
          ),
        ),
      );
    });
  });

  group('inspect', () {
    test('returns the config summary', () async {
      const ref = 'docker.io/library/alpine:3.19';
      bridge.imageInspectResponses[ref] = inspection(ref);
      final result = await service.inspect(ref);
      expect(result.layers, 3);
      expect(result.platforms, ['linux/arm64', 'linux/amd64']);
      expect(result.env, ['PATH=/usr/bin']);
      expect(result.entrypoint, ['/bin/sh']);
      expect(result.cmd, ['-c', 'serve']);
      expect(result.exposedPorts, ['80/tcp']);
      expect(result.labels['org.opencontainers.image.title'], 'demo');
      expect(result.sizeBytes, 7340032);
    });

    test('validates the reference before touching the bridge', () async {
      await expectLater(
        service.inspect('alpine@sha256:${'a' * 64}'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.invalidArgument,
          ),
        ),
      );
      expect(bridge.calls.where((c) => c.startsWith('imageInspect')), isEmpty);
    });

    test('maps unknown references to NOT_FOUND', () {
      expect(
        () => service.inspect('docker.io/library/ghost:9'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.notFound,
          ),
        ),
      );
    });
  });

  group('delete', () {
    test('deletes an unreferenced image', () async {
      const ref = 'docker.io/library/alpine:3.19';
      bridge.images = [description(ref)];
      await service.delete(ref);
      expect(bridge.deletedImages, [ref]);
      expect(bridge.images, isEmpty);
    });

    test('refuses images referenced by containers with a clear CONFLICT', () {
      const ref = 'docker.io/library/nginx:latest';
      bridge.containers = [
        snapshotPayload(id: 'web'),
        snapshotPayload(id: 'db'),
      ];
      expect(
        () => service.delete(ref),
        throwsA(
          isA<GcmException>()
              .having((e) => e.code, 'code', GcmErrorCode.conflict)
              .having((e) => e.message, 'message', contains('web'))
              .having((e) => e.message, 'message', contains('db')),
        ),
      );
    });

    test(
      'allows deleting when referencing containers use another tag',
      () async {
        const ref = 'docker.io/library/nginx:1.27';
        bridge.images = [description(ref)];
        bridge.containers = [snapshotPayload(id: 'web')]; // nginx:latest
        await service.delete(ref);
        expect(bridge.deletedImages, [ref]);
      },
    );

    test('maps upstream in-use refusals to CONFLICT', () {
      const ref = 'docker.io/library/alpine:3.19';
      bridge.imageDeleteFailures[ref] = 'image is in use by container x';
      expect(
        () => service.delete(ref),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.conflict,
          ),
        ),
      );
    });
  });

  group('pull', () {
    test('completes with the pulled image and forwards progress', () async {
      final progress = <ImagePullProgress>[];
      final pullId = service.newPullId();
      // Hold the fake pull open so progress events arrive while the
      // service-side subscription is still alive.
      final blocker = Completer<void>();
      bridge.pullBlocker = blocker;
      final future = service.pull(
        reference: 'alpine:3.19',
        pullId: pullId,
        onProgress: progress.add,
      );
      // The bridge subscribes to the broadcast stream asynchronously; let the
      // microtask queue settle so no progress event is dropped.
      await pumpEventQueue();
      bridge.pullEventsController.add(
        BridgeImagePullEvent(
          pullId: pullId,
          description: '下载中',
          completedBytes: 1024,
          totalBytes: 2048,
          itemsDone: 1,
          itemsTotal: 2,
        ),
      );
      // Other pulls' events are filtered out.
      bridge.pullEventsController.add(
        BridgeImagePullEvent(pullId: 'other', completedBytes: 9),
      );
      await pumpEventQueue();
      blocker.complete();
      final outcome = await future;
      expect(outcome, isA<ImagePullCompleted>());
      final image = (outcome as ImagePullCompleted).image;
      expect(image.reference, 'alpine:3.19');
      expect(progress, hasLength(1));
      expect(progress.single.fraction, 0.5);
      expect(progress.single.description, '下载中');
    });

    test('cancel resolves with ImagePullCancelled', () async {
      bridge.pullHangs = true;
      final pullId = service.newPullId();
      final future = service.pull(reference: 'alpine:3.19', pullId: pullId);
      await pumpEventQueue();
      await service.cancelPull(pullId);
      expect(await future, isA<ImagePullCancelled>());
      expect(bridge.pullCancelCalls, [pullId]);
    });

    test('maps pull failures', () {
      bridge.pullFailure = 'connection invalid';
      expect(
        () => service.pull(reference: 'alpine:3.19'),
        throwsA(
          isA<GcmException>().having(
            (e) => e.code,
            'code',
            GcmErrorCode.runtimeUnavailable,
          ),
        ),
      );
    });
  });
}
