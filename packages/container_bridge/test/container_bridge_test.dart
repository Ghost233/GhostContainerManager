import 'package:container_bridge/container_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
