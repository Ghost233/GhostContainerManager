import Cocoa
import FlutterMacOS

/// Placeholder native bridge for Apple container operations.
///
/// P0 scaffold: registers the method/event channels and answers every call
/// with `notImplemented`. The real implementation links ContainerAPIClient
/// (XPC) plus a CLI process wrapper; see docs/spec/architecture.md §2/§3.
public class ContainerBridgePlugin: NSObject, FlutterPlugin {
  public static let methodsChannelName = "com.ghost233.container_bridge/methods"
  public static let eventsChannelName = "com.ghost233.container_bridge/events"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ContainerBridgePlugin()
    let methods = FlutterMethodChannel(
      name: methodsChannelName,
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: eventsChannelName,
      binaryMessenger: registrar.messenger
    )
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}

extension ContainerBridgePlugin: FlutterStreamHandler {
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    return FlutterError(
      code: "notImplemented",
      message: "container_bridge event streams are not implemented yet.",
      details: nil
    )
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }
}
