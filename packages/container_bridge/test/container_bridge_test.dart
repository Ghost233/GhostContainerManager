import 'package:container_bridge/container_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('channel names match the Swift side', () {
    expect(
      ContainerBridgeChannels.methods,
      'com.ghost233.container_bridge/methods',
    );
    expect(
      ContainerBridgeChannels.events,
      'com.ghost233.container_bridge/events',
    );
    expect(
      ContainerBridgeChannels.cliEvents,
      'com.ghost233.container_bridge/cli-events',
    );
  });

  test('container write methods encode method names and arguments', () async {
    const channel = MethodChannel(ContainerBridgeChannels.methods);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object?>{};
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = ContainerBridgeChannel(channel: channel);

    await bridge.containerCreate(
      id: 'web',
      image: 'docker.io/library/nginx:latest',
      command: ['nginx'],
      env: ['MODE=prod'],
      ports: ['8080:80/tcp'],
      network: 'default',
      mounts: [
        {'source': '/tmp/data', 'target': '/data', 'readonly': true},
      ],
      labels: {'role': 'web'},
    );
    await bridge.containerStart('web');
    await bridge.containerStop('web', timeoutSeconds: 7);
    await bridge.containerKill('web', signal: 'TERM');
    await bridge.containerDelete('web', force: true);

    expect(calls.map((call) => call.method), [
      'container.create',
      'container.start',
      'container.stop',
      'container.kill',
      'container.delete',
    ]);
    expect(calls[0].arguments, {
      'id': 'web',
      'image': 'docker.io/library/nginx:latest',
      'command': ['nginx'],
      'env': ['MODE=prod'],
      'ports': ['8080:80/tcp'],
      'network': 'default',
      'mounts': [
        {'source': '/tmp/data', 'target': '/data', 'readonly': true},
      ],
      'labels': {'role': 'web'},
    });
    expect(calls[1].arguments, {'id': 'web'});
    expect(calls[2].arguments, {'id': 'web', 'timeoutSeconds': 7});
    expect(calls[3].arguments, {'id': 'web', 'signal': 'TERM'});
    expect(calls[4].arguments, {'id': 'web', 'force': true});
  });

  test('container exec encodes its non-TTY process options', () async {
    const channel = MethodChannel(ContainerBridgeChannels.methods);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object?>{
            'exitCode': 17,
            'stdout': 'out',
            'stderr': 'err',
            'truncated': false,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = ContainerBridgeChannel(channel: channel);

    final result = await bridge.containerExec(
      id: 'web',
      command: ['printenv', 'MODE'],
      env: ['MODE=prod'],
      workdir: '/srv/app',
      user: 'www',
      timeoutSeconds: 42,
    );

    expect(calls.single.method, 'container.exec');
    expect(calls.single.arguments, {
      'id': 'web',
      'command': ['printenv', 'MODE'],
      'env': ['MODE=prod'],
      'workdir': '/srv/app',
      'user': 'www',
      'timeoutSeconds': 42,
    });
    expect(result['exitCode'], 17);
    expect(result['stdout'], 'out');
    expect(result['stderr'], 'err');
  });

  group('generic cli', () {
    test('cliRun/cliStart/cliTerminate use the agreed wire contract', () async {
      const methodChannel = MethodChannel(ContainerBridgeChannels.methods);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            calls.add(call);
            return <String, Object?>{};
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, null);
      });
      final channel = ContainerBridgeChannel(channel: methodChannel);

      await channel.cliRun([
        'compose',
        'up',
        '-d',
      ], timeout: const Duration(milliseconds: 1500));
      await channel.cliStart(['compose', 'up'], handle: 'handle-1');
      await channel.cliTerminate('handle-1');

      expect(calls[0].method, 'cliRun');
      expect(calls[0].arguments, {
        'arguments': ['compose', 'up', '-d'],
        'timeoutSeconds': 1.5,
      });
      expect(calls[1].method, 'cliStart');
      expect(calls[1].arguments, {
        'arguments': ['compose', 'up'],
        'handle': 'handle-1',
      });
      expect(calls[2].method, 'cliTerminate');
      expect(calls[2].arguments, {'handle': 'handle-1'});
    });

    test('cliProcess listens and cancels the cli.process stream', () async {
      const name = ContainerBridgeChannels.cliEvents;
      const methodChannel = MethodChannel(name);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, null);
      });
      final mainCalls = <MethodCall>[];
      const mainChannel = MethodChannel(ContainerBridgeChannels.events);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mainChannel, (call) async {
            mainCalls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mainChannel, null);
      });
      final events = ContainerBridgeEvents();

      final subscription = events.cliProcess('handle-1').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(calls.map((call) => call.method), ['listen', 'cancel']);
      expect(mainCalls, isEmpty);
      for (final call in calls) {
        expect(call.arguments, {'stream': 'cli.process', 'handle': 'handle-1'});
      }
    });
  });
}
