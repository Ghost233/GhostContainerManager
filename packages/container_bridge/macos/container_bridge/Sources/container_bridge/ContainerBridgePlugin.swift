import Cocoa
import ContainerAPIClient
import ContainerizationOCI
import FlutterMacOS

/// Native bridge for Apple container operations (system domain first).
///
/// Routing (docs/spec/architecture.md §2/§3, research report):
/// - XPC (ContainerAPIClient): health, container lifecycle, and images.
///   Ping doubles as the apiserver liveness probe.
/// - CLI (`CliRunner`): system start/stop/kernel installation plus network
///   and compose operations that are outside the XPC API.
///
/// The Dart side (lib/services/) owns all decisions; this layer only
/// executes and returns raw payloads. Bridge-API probes (binary lookup,
/// kernel symlink check) are resolved Dart-side via dart:io and never
/// reach Swift; CliRunner still probes /usr/local/bin and
/// /opt/homebrew/bin on its own, but only to locate the `container`
/// binary when spawning CLI subprocesses.
public class ContainerBridgePlugin: NSObject, FlutterPlugin {
  public static let methodsChannelName = "com.ghost233.container_bridge/methods"
  public static let eventsChannelName = "com.ghost233.container_bridge/events"

  private let pingTimeoutSeconds: TimeInterval = 5

  /// Active container log stream sessions, keyed by container id.
  /// Mutated on the main queue only.
  private var logSessions: [String: ContainerLogStreamSession] = [:]

  /// In-flight image pulls, keyed by pullId (Dart issues the ids).
  /// `image.pullCancel` removes and cancels the entry; completion only
  /// answers the Flutter result when the entry is still present.
  /// Mutated on the main queue only.
  private var pullTasks: [String: Task<Void, Never>] = [:]

  /// Sink for the "image.pull" event stream (single subscriber — the Dart
  /// side fans out per pullId). Mutated on the main queue only.
  private var imagePullSink: FlutterEventSink?

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
    case "container.exec":
      guard let id = args?["id"] as? String,
        let command = args?["command"] as? [String],
        !command.isEmpty
      else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.exec requires 'id' and a non-empty 'command' string array.",
            details: nil
          )
        )
        return
      }
      let env = args?["env"] as? [String] ?? []
      let timeoutSeconds = args?["timeoutSeconds"] as? Int ?? 60
      containerWrite(result: result) {
        try await ExecOps.run(
          id: id,
          command: command,
          env: env,
          workdir: args?["workdir"] as? String,
          user: args?["user"] as? String,
          timeoutSeconds: timeoutSeconds
        )
      }
    case "container.create":
      guard let id = args?["id"] as? String,
        let image = args?["image"] as? String
      else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.create requires 'id' and 'image' string arguments.",
            details: nil
          )
        )
        return
      }
      let command = args?["command"] as? [String] ?? []
      let env = args?["env"] as? [String] ?? []
      let ports = args?["ports"] as? [String] ?? []
      containerWrite(result: result) {
        try await ContainerOps.create(
          id: id,
          image: image,
          command: command,
          env: env,
          ports: ports,
          network: args?["network"] as? String
        )
      }
    case "container.start":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.start requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      containerWrite(result: result) { try await ContainerOps.start(id: id) }
    case "container.stop":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.stop requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      let timeoutSeconds = args?["timeoutSeconds"] as? Int ?? 5
      containerWrite(result: result) {
        try await ContainerOps.stop(id: id, timeoutSeconds: Int32(timeoutSeconds))
      }
    case "container.delete":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.delete requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      let force = args?["force"] as? Bool ?? false
      containerWrite(result: result) {
        try await ContainerOps.delete(id: id, force: force)
      }
    case "container.kill":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "container.kill requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      let signal = args?["signal"] as? String ?? "KILL"
      containerWrite(result: result) {
        try await ContainerOps.kill(id: id, signal: signal)
      }
    case "image.list":
      imageList(result: result)
    case "image.inspect":
      guard let reference = args?["reference"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "image.inspect requires a 'reference' string argument.",
            details: nil
          )
        )
        return
      }
      imageInspect(reference: reference, result: result)
    case "image.delete":
      guard let reference = args?["reference"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "image.delete requires a 'reference' string argument.",
            details: nil
          )
        )
        return
      }
      imageDelete(reference: reference, result: result)
    case "image.pull":
      guard let pullId = args?["pullId"] as? String,
        let reference = args?["reference"] as? String
      else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "image.pull requires 'pullId' and 'reference' string arguments.",
            details: nil
          )
        )
        return
      }
      imagePull(
        pullId: pullId,
        reference: reference,
        platform: args?["platform"] as? String,
        result: result
      )
    case "image.pullCancel":
      guard let pullId = args?["pullId"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "image.pullCancel requires a 'pullId' string argument.",
            details: nil
          )
        )
        return
      }
      imagePullCancel(pullId: pullId, result: result)
    case "network.list":
      runCli(["network", "ls", "--format", "json"], result: result)
    case "network.inspect":
      guard let id = args?["id"] as? String else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "network.inspect requires an 'id' string argument.",
            details: nil
          )
        )
        return
      }
      runCli(["network", "inspect", id], result: result)
    case "compose.help":
      // Plugin-presence probe: exit 0 + up/down listing = plugin installed.
      runCli(["compose", "--help"], result: result)
    case "compose.run":
      // The Dart Service layer builds the argument vector (flag decisions
      // live there); this side only forwards to the plugin CLI.
      guard let composeArgs = args?["arguments"] as? [String], !composeArgs.isEmpty else {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "compose.run requires a non-empty 'arguments' string array.",
            details: nil
          )
        )
        return
      }
      let timeoutSeconds = (args?["timeoutSeconds"] as? Int) ?? 600
      runCli(
        ["compose"] + composeArgs,
        timeout: TimeInterval(timeoutSeconds),
        result: result
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Shared XPC write forwarding. Raw runtime errors stay intact for the
  /// Dart Service's feature-fingerprint mapper.
  private func containerWrite(
    result: @escaping FlutterResult,
    operation: @escaping () async throws -> [String: Any]
  ) {
    Task {
      do {
        let payload = try await operation()
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

  // MARK: - Image domain (ClientImage over container-core-images XPC)

  private func imageList(result: @escaping FlutterResult) {
    Task {
      do {
        let payload = try await ImageOps.list()
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

  private func imageInspect(reference: String, result: @escaping FlutterResult) {
    Task {
      do {
        let payload = try await ImageOps.inspect(reference: reference)
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

  private func imageDelete(reference: String, result: @escaping FlutterResult) {
    Task {
      do {
        try await ImageOps.delete(reference: reference)
        await MainActor.run { result(["reference": reference, "deleted": true]) }
      } catch {
        await MainActor.run {
          result(
            FlutterError(code: "xpcError", message: error.localizedDescription, details: nil)
          )
        }
      }
    }
  }

  /// Starts a pull tracked under [pullId]. Progress flows through
  /// PullProgressTracker (~10 Hz) onto the "image.pull" event stream.
  private func imagePull(
    pullId: String,
    reference: String,
    platform: String?,
    result: @escaping FlutterResult
  ) {
    var parsedPlatform: Platform?
    if let platform {
      do {
        parsedPlatform = try Platform(from: platform)
      } catch {
        result(
          FlutterError(
            code: "invalidArgument",
            message: "invalid platform '\(platform)': \(error.localizedDescription)",
            details: nil
          )
        )
        return
      }
    }
    let tracker = PullProgressTracker(pullId: pullId) { [weak self] payload in
      DispatchQueue.main.async { self?.imagePullSink?(payload) }
    }
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let description = try await ImageOps.pull(
          reference: reference,
          platform: parsedPlatform,
          progress: { events in await tracker.consume(events) }
        )
        await MainActor.run {
          // Only answer when the pull is still tracked — a cancelled pull had
          // its result answered by imagePullCancel already.
          if self.pullTasks.removeValue(forKey: pullId) != nil {
            result(ImageOps.descriptionMap(description))
          }
        }
      } catch {
        await MainActor.run {
          if self.pullTasks.removeValue(forKey: pullId) != nil {
            result(
              FlutterError(code: "xpcError", message: error.localizedDescription, details: nil)
            )
          }
        }
      }
    }
    pullTasks[pullId] = task
  }

  /// v1 cancellation semantics: no server-side cancel route exists, so we
  /// cancel the local waiting task and report `cancelled` to Dart; the
  /// runtime may still finish the pull in the background. Unknown pullIds
  /// are ignored (Dart may cancel after completion).
  private func imagePullCancel(pullId: String, result: @escaping FlutterResult) {
    guard let task = pullTasks.removeValue(forKey: pullId) else {
      result(["cancelled": false])
      return
    }
    task.cancel()
    result(["cancelled": true])
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
      let stream = args["stream"] as? String
    else {
      return FlutterError(
        code: "invalidArgument",
        message: "events channel requires {'stream': <name>, ...}.",
        details: nil
      )
    }
    if stream == "image.pull" {
      imagePullSink = events
      return nil
    }
    guard stream == "container.logs", let id = args["id"] as? String
    else {
      return FlutterError(
        code: "invalidArgument",
        message: "unknown event stream '\(stream)'.",
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
    if let args = arguments as? [String: Any] {
      if args["stream"] as? String == "image.pull" {
        imagePullSink = nil
        return nil
      }
      if let id = args["id"] as? String {
        logSessions.removeValue(forKey: id)?.cancel()
      }
    }
    return nil
  }
}
