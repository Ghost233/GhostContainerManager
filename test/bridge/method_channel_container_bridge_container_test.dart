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
