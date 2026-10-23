/// Native bridge plugin for Apple container operations (P0 placeholder).
///
/// The Dart-facing abstract seam (`ContainerBridge`) lives in the app's
/// `lib/bridge/`; this package carries the Swift implementation
/// (ContainerAPIClient over XPC + CLI process wrapper). See
/// docs/spec/architecture.md §2/§3.
library;

/// Channel names shared with the Swift side
/// (`macos/container_bridge/Sources/container_bridge/ContainerBridgePlugin.swift`).
abstract final class ContainerBridgeChannels {
  /// Method channel for request/response operations.
  static const String methods = 'com.ghost233.container_bridge/methods';

  /// Event channel for streams (logs, pull progress, stats).
  static const String events = 'com.ghost233.container_bridge/events';
}
