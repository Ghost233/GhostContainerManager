import Cocoa
import ContainerAPIClient
import FlutterMacOS

/// Native bridge for Apple container operations (system domain first).
///
/// Routing (docs/spec/architecture.md §2/§3, research report):
/// - XPC (ContainerAPIClient): health ping. XPC is unusable while the
///   apiserver is down, so ping doubles as the service liveness probe.
/// - CLI (`CliRunner`): everything else — XPC exposes no routes for
///   system start/stop or the recommended kernel install.
///
/// The Dart side (lib/services/) owns all decisions; this layer only
/// executes and returns raw payloads. Methods that the Dart adapter can
/// resolve locally (binary lookup, kernel symlink check) never reach
/// Swift.
public class ContainerBridgePlugin: NSObject, FlutterPlugin {
  public static let methodsChannelName = "com.ghost233.container_bridge/methods"
  public static let eventsChannelName = "com.ghost233.container_bridge/events"

  private let pingTimeoutSeconds: TimeInterval = 5

  /// Active container log stream sessions, keyed by container id.
  /// Mutated on the main queue only.
  private var logSessions: [String: ContainerLogStreamSession] = [:]

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
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "system.version":
      runCli(["system", "version", "--format", "json"], result: result)
    case "system.status":
      runCli(["system", "status", "--format", "json"], result: result)
    case "system.start":
      // MUST pass an explicit kernel-install flag; without it the CLI
      // blocks on readLine and dies with "failed to read user input".
      let installKernel = (args?["installKernel"] as? Bool) ?? false
      let flag = installKernel ? "--enable-kernel-install" : "--disable-kernel-install"
      runCli(["system", "start", flag], timeout: 120, result: result)
    case "system.stop":
      runCli(["system", "stop"], result: result)
    case "system.kernelSet":
      let force = (args?["force"] as? Bool) ?? false
      var kernelArgs = ["system", "kernel", "set", "--recommended"]
      if force { kernelArgs.append("--force") }
      runCli(kernelArgs, timeout: 300, result: result)
    case "system.ping":
      ping(result: result)
    case "container.list":
      containerList(result: result)
    case "container.get":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.get requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      containerInspect(id: id, result: result)
    case "container.stats":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.stats requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      containerStats(id: id, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// XPC container list. Raw error text is returned for the Dart mapper
  /// ("connection invalid" → service down; "not found" → NOT_FOUND, ...).
  private func containerList(result: @escaping FlutterResult) {
    Task {
      do {
        let payload = try await ContainerOps.list()
        await MainActor.run { result(payload) }
      } catch {
        await MainActor.run {
          result(
            FlutterError(code: "xpcError", message: error.localizedDescription, details: nil)
          )
        }
      }
    }
  }

  private func containerInspect(id: String, result: @escaping FlutterResult) {
    Task {
      do {
        let payload = try await ContainerOps.inspect(id: id)
        await MainActor.run { result(payload) }
      } catch {
        await MainActor.run {
          result(
            FlutterError(code: "xpcError", message: error.localizedDescription, details: nil)
          )
        }
      }
    }
  }

  /// Single stats snapshot. Streaming/rate computation is the Dart side's
  /// job (polling, see docs/spec/architecture.md §5).
  private func containerStats(id: String, result: @escaping FlutterResult) {
    Task {
      do {
        let payload = try await ContainerOps.stats(id: id)
        await MainActor.run { result(payload) }
      } catch {
        await MainActor.run {
          result(
            FlutterError(code: "xpcError", message: error.localizedDescription, details: nil)
          )
        }
      }
    }
  }

  private func runCli(
    _ arguments: [String],
    timeout: TimeInterval = 60,
    result: @escaping FlutterResult
  ) {
    guard let binary = CliRunner.locateBinary() else {
      result(
        FlutterError(
          code: "runtimeUnavailable",
          message: "container CLI not found in /usr/local/bin or /opt/homebrew/bin.",
          details: nil
        )
      )
      return
    }
    CliRunner.run(binary: binary, arguments: arguments, timeout: timeout) { cliResult in
      DispatchQueue.main.async {
        result(cliResult.asDictionary)
      }
    }
  }

  /// XPC health check. On failure the raw error message is returned so the
  /// Dart mapper can classify it ("connection invalid" → service down;
  /// "failed to decode ... health check" → version mismatch).
  private func ping(result: @escaping FlutterResult) {
    Task {
      do {
        let health = try await ClientHealthCheck.ping(
          timeout: .seconds(Int64(pingTimeoutSeconds))
        )
        await MainActor.run {
          result([
            "ok": true,
            "appRoot": health.appRoot.absoluteString,
            "installRoot": health.installRoot.absoluteString,
            "logRoot": health.logRoot?.string ?? "",
            "apiServerVersion": health.apiServerVersion,
            "apiServerCommit": health.apiServerCommit,
            "apiServerBuild": health.apiServerBuild,
            "apiServerAppName": health.apiServerAppName,
          ])
        }
      } catch {
        await MainActor.run {
          result([
            "ok": false,
            "error": error.localizedDescription,
          ])
        }
      }
    }
  }
}

extension ContainerBridgePlugin: FlutterStreamHandler {
  /// Subscribes to a bridge event stream. Arguments select the stream:
  /// `{"stream": "container.logs", "id": <container id>}` — wires the XPC
  /// log FileHandles (stdio + boot) to the event sink.
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard
      let args = arguments as? [String: Any],
      let stream = args["stream"] as? String,
      stream == "container.logs",
      let id = args["id"] as? String
    else {
      return FlutterError(
        code: "invalidArgument",
        message: "events channel requires {'stream': 'container.logs', 'id': ...}.",
        details: nil
      )
    }
    // Replace any previous session for the same container.
    logSessions[id]?.cancel()
    let session = ContainerLogStreamSession(containerId: id, sink: events)
    session.onFinish = { [weak self] finished in
      self?.logSessions.removeValue(forKey: finished.containerId)
    }
    logSessions[id] = session
    session.start()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let args = arguments as? [String: Any], let id = args["id"] as? String {
      logSessions.removeValue(forKey: id)?.cancel()
    }
    return nil
  }
}
