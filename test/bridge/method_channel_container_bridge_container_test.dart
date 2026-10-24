import 'dart:async';

import 'package:container_bridge/container_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/method_channel_container_bridge.dart';

/// Scripted [ContainerBridgeChannel] substitute.
class _ScriptedChannel extends ContainerBridgeChannel {
  final List<Object> listResponses = [];
  final Map<String, Object> getResponses = {};
  final Map<String, Object> statsResponses = {};
  final Map<String, Map<String, Object?>> writeCalls = {};
  final Map<String, Map<String, Object?>> writeResponses = {};
  Object? writeError;
  Map<String, Object?> execResponse = {
    'exitCode': 0,
    'stdout': '',
    'stderr': '',
    'stdoutTruncated': false,
    'stderrTruncated': false,
  };

  Future<Map<String, Object?>> _recordWrite(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final error = writeError;
    if (error != null) throw error;
    writeCalls[method] = arguments;
    return writeResponses[method] ?? const {};
  }

  @override
  Future<Map<String, Object?>> containerCreate({
    required String id,
    required String image,
    List<String> command = const [],
    List<String> env = const [],
    List<String> ports = const [],
    String? network,
    List<Map<String, Object?>> mounts = const [],
    Map<String, String> labels = const {},
  }) async {
    return _recordWrite('create', {
      'id': id,
      'image': image,
      'command': command,
      'env': env,
      'ports': ports,
      'network': network,
      'mounts': mounts,
      'labels': labels,
    });
  }

  @override
  Future<Map<String, Object?>> containerStart(String id) async {
    return _recordWrite('start', {'id': id});
  }

  @override
  Future<Map<String, Object?>> containerStop(
    String id, {
    int timeoutSeconds = 5,
  }) async {
    return _recordWrite('stop', {'id': id, 'timeoutSeconds': timeoutSeconds});
  }

  @override
  Future<Map<String, Object?>> containerDelete(
    String id, {
    bool force = false,
  }) async {
    return _recordWrite('delete', {'id': id, 'force': force});
  }

  @override
  Future<Map<String, Object?>> containerKill(
    String id, {
    String signal = 'KILL',
  }) async {
    return _recordWrite('kill', {'id': id, 'signal': signal});
  }

  @override
  Future<Map<String, Object?>> containerExec({
    required String id,
    required List<String> command,
    List<String> env = const [],
    String? workdir,
    String? user,
    int timeoutSeconds = 60,
  }) async {
    await _recordWrite('exec', {
      'id': id,
      'command': command,
      'env': env,
      'workdir': workdir,
      'user': user,
      'timeoutSeconds': timeoutSeconds,
    });
    return execResponse;
  }

  @override
  Future<List<Map<String, Object?>>> containerList() async {
    final next = listResponses.removeAt(0);
    if (next is Exception) throw next;
    return (next as List).cast<Map<String, Object?>>();
  }

  @override
  Future<Map<String, Object?>> containerGet(String id) async {
    final next = getResponses.remove(id)!;
    if (next is Exception) throw next;
    return (next as Map).cast<String, Object?>();
  }

  @override
  Future<Map<String, Object?>> containerStats(String id) async {
    final next = statsResponses.remove(id)!;
    if (next is Exception) throw next;
    return (next as Map).cast<String, Object?>();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelContainerBridge container domain', () {
    test('containerList returns snapshot maps', () async {
      final channel = _ScriptedChannel()
        ..listResponses.add([
          {
            'configuration': {'id': 'web'},
            'status': 'running',
          },
        ]);
      final bridge = MethodChannelContainerBridge(channel: channel);

      final list = await bridge.containerList();

      expect(list, hasLength(1));
      expect(
        (list.single['configuration']! as Map<String, Object?>)['id'],
        'web',
      );
    });

    test('PlatformException is converted to BridgeCallException', () async {
      final channel = _ScriptedChannel()
        ..listResponses.add(
          PlatformException(code: 'xpcError', message: 'connection invalid'),
        )
        ..getResponses['gone'] = PlatformException(
          code: 'xpcError',
          message: 'container not found',
        )
        ..statsResponses['dead'] = PlatformException(
          code: 'xpcError',
          message: 'container is not running',
        );
      final bridge = MethodChannelContainerBridge(channel: channel);

      await expectLater(
        bridge.containerList(),
        throwsA(
          isA<BridgeCallException>().having(
            (e) => e.message,
            'message',
            contains('connection invalid'),
          ),
        ),
      );
      await expectLater(
        bridge.containerInspect('gone'),
        throwsA(isA<BridgeCallException>()),
      );
      await expectLater(
        bridge.containerStats('dead'),
        throwsA(isA<BridgeCallException>()),
      );
    });

    test('write operations forward all lifecycle arguments', () async {
      final channel = _ScriptedChannel()
        ..writeResponses['stop'] = {'stoppedGracefully': false}
        ..writeResponses['kill'] = {'status': 'running'};
      final bridge = MethodChannelContainerBridge(channel: channel);

      await bridge.containerCreate(
        id: 'web',
        image: 'docker.io/library/nginx:latest',
        command: ['nginx', '-g', 'daemon off;'],
        env: ['MODE=prod'],
        ports: ['8080:80/tcp'],
        network: 'default',
        mounts: [
          {'source': '/tmp/data', 'target': '/data', 'readonly': true},
        ],
        labels: {'role': 'web'},
      );
      await bridge.containerStart('web');
      final stoppedGracefully = await bridge.containerStop(
        'web',
        timeoutSeconds: 7,
      );
      final status = await bridge.containerKill('web', signal: 'TERM');
      await bridge.containerDelete('web', force: true);

      expect(stoppedGracefully, isFalse);
      expect(status, 'running');

      expect(channel.writeCalls, {
        'create': {
          'id': 'web',
          'image': 'docker.io/library/nginx:latest',
          'command': ['nginx', '-g', 'daemon off;'],
          'env': ['MODE=prod'],
          'ports': ['8080:80/tcp'],
          'network': 'default',
          'mounts': [
            {'source': '/tmp/data', 'target': '/data', 'readonly': true},
          ],
          'labels': {'role': 'web'},
        },
        'start': {'id': 'web'},
        'stop': {'id': 'web', 'timeoutSeconds': 7},
        'kill': {'id': 'web', 'signal': 'TERM'},
        'delete': {'id': 'web', 'force': true},
      });
    });

    test('all write PlatformExceptions become BridgeCallException', () async {
      final channel = _ScriptedChannel()
        ..writeError = PlatformException(
          code: 'xpcError',
          message: 'runtime unavailable',
        );
      final bridge = MethodChannelContainerBridge(channel: channel);
      final calls = <Future<void> Function()>[
        () => bridge.containerCreate(id: 'web', image: 'local/image:latest'),
        () => bridge.containerStart('web'),
        () => bridge.containerStop('web'),
        () => bridge.containerKill('web'),
        () => bridge.containerDelete('web'),
      ];

      for (final call in calls) {
        await expectLater(
          call(),
          throwsA(
            isA<BridgeCallException>().having(
              (error) => error.message,
              'message',
              'runtime unavailable',
            ),
          ),
        );
      }
    });

    test(
      'container exec forwards options and decodes bounded output',
      () async {
        final channel = _ScriptedChannel()
          ..execResponse = {
            'exitCode': 23,
            'stdout': 'partial out',
            'stderr': 'err',
            'stdoutTruncated': true,
            'stderrTruncated': false,
          };
        final bridge = MethodChannelContainerBridge(channel: channel);

        final result = await bridge.containerExec(
          id: 'web',
          command: ['ls', '/tmp'],
          env: ['LANG=C'],
          workdir: '/srv',
          user: 'www',
          timeoutSeconds: 12,
        );

        expect(channel.writeCalls['exec'], {
          'id': 'web',
          'command': ['ls', '/tmp'],
          'env': ['LANG=C'],
          'workdir': '/srv',
          'user': 'www',
          'timeoutSeconds': 12,
        });
        expect(result.exitCode, 23);
        expect(result.stdout, 'partial out');
        expect(result.stderr, 'err');
        expect(result.stdoutTruncated, isTrue);
        expect(result.stderrTruncated, isFalse);
        expect(result.truncated, isTrue);
        expect(result.timedOut, isFalse);
      },
    );

    test('containerLogs decodes data/eof/error events', () async {
      final controller = StreamController<Map<String, Object?>>();
      final events = _ScriptedEvents(controller.stream);
      final bridge = MethodChannelContainerBridge(events: events);

      final collected = <BridgeLogEvent>[];
      final done = Completer<void>();
      final sub = bridge
          .containerLogs('web')
          .listen(collected.add, onDone: done.complete);
      controller
        ..add({'source': 'stdio', 'data': Uint8List.fromList('hi'.codeUnits)})
        ..add({'event': 'error', 'message': 'boom'})
        ..add({'event': 'eof'});
      await controller.close();
      await done.future;
      await sub.cancel();

      expect(collected[0].event, 'data');
      expect(collected[0].source, 'stdio');
      expect(String.fromCharCodes(collected[0].bytes), 'hi');
      expect(collected[1].event, 'error');
      expect(collected[1].message, 'boom');
      expect(collected[2].event, 'eof');
    });
  });
}

class _ScriptedEvents extends ContainerBridgeEvents {
  _ScriptedEvents(this._stream);
  final Stream<Map<String, Object?>> _stream;

  @override
  Stream<Map<String, Object?>> containerLogs(String id) => _stream;
}
