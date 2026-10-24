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
}
