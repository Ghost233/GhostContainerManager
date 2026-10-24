import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import FlutterMacOS
import Foundation

/// Container-domain XPC operations (`ContainerClient` over
/// `com.apple.container.apiserver`).
///
/// Payloads are JSON-encoded snapshots returned as plain dictionaries for
/// the Flutter channel; ALL interpretation (field mapping, filtering,
/// error classification) happens in the Dart Service layer (E02).
enum ContainerOps {
  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    // ISO-8601 strings so Dart can `DateTime.parse` them directly.
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  /// Encodes one Codable payload to a channel-friendly dictionary.
  static func toDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try makeEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any] else {
      throw NSError(
        domain: "container_bridge",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "encoded XPC payload is not a dictionary"]
      )
    }
    return dict
  }

  /// `ContainerClient.list()` — unfiltered; label/status filtering is a
  /// Service-layer concern so its semantics stay testable with the fake.
  static func list() async throws -> [[String: Any]] {
    let snapshots = try await ContainerClient().list()
    let data = try makeEncoder().encode(snapshots)
    return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
  }

  /// `ContainerClient.get(id:)` — full snapshot incl. configuration.
  static func inspect(id: String) async throws -> [String: Any] {
    try await toDictionary(ContainerClient().get(id: id))
  }

  /// `ContainerClient.stats(id:)` — single snapshot; streaming is done by
  /// polling on the Dart side (orchard pattern: 2s foreground / 10s
  /// background, see docs/spec/architecture.md §5).
  static func stats(id: String) async throws -> [String: Any] {
    try await toDictionary(ContainerClient().stats(id: id))
  }

  /// Create from an image that is already present locally. This deliberately
  /// uses `ClientImage.get`, not `Utility.containerConfigFromFlags` (which
  /// fetches missing images), so a write never becomes an implicit pull.
  static func create(
    id: String,
    image reference: String,
    command: [String],
    env: [String],
    ports: [String],
    network: String?,
    mounts: [[String: Any]],
    labels: [String: String]
  ) async throws -> [String: Any] {
    let systemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: systemConfig
    )
    let imageConfig = try await image.config(for: .current).config
    var processFlags = Flags.Process()
    processFlags.env = env
    var configuration = ContainerConfiguration(
      id: id,
      image: image.description,
      process: try Parser.process(
        arguments: command,
        processFlags: processFlags,
        managementFlags: Flags.Management(),
        config: imageConfig
      )
    )
    configuration.publishedPorts = try Parser.publishPorts(ports)
    configuration.mounts = try mounts.map { raw in
      guard let source = raw["source"] as? String,
        let target = raw["target"] as? String,
        !source.isEmpty,
        source.hasPrefix("/"),
        target.hasPrefix("/")
      else {
        throw NSError(
          domain: "container_bridge",
          code: 5,
          userInfo: [
            NSLocalizedDescriptionKey:
              "invalid mount: source and target must be absolute paths"
          ]
        )
      }
      let readonly = raw["readonly"] as? Bool ?? false
      return Filesystem.virtiofs(
        source: source,
        destination: target,
        options: readonly ? ["ro"] : []
      )
    }
    configuration.labels = labels

    let networkClient = NetworkClient()
    let attachment: NetworkResource
    if let network {
      attachment = try await networkClient.get(id: network)
    } else if let builtin = try await networkClient.builtin {
      attachment = builtin
    } else {
      throw NSError(
        domain: "container_bridge",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "default container network not found"]
      )
    }
    configuration.networks = [
      AttachmentConfiguration(
        network: attachment.id,
        options: AttachmentOptions(hostname: id, macAddress: nil, mtu: 1280)
      )
    ]
    configuration.dns = ContainerConfiguration.DNSConfiguration(
      domain: systemConfig.dns.domain
    )

    let kernel = try await ClientKernel.getDefaultKernel(for: .current)
    try await ContainerClient().create(configuration: configuration, kernel: kernel)
    return ["id": id]
  }

  /// Start is idempotent for an already-running container. Detached stdio is
  /// left to the runtime; logs remain available through container.logs.
  static func start(id: String) async throws -> [String: Any] {
    let client = ContainerClient()
    let snapshot = try await client.get(id: id)
    if snapshot.status != .running {
      do {
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
      } catch {
        try? await client.stop(id: id)
        throw error
      }
    }
    return ["id": id]
  }

  /// Apple container enforces this graceful stop and then sends SIGKILL.
  /// The runtime does not report escalation, so `stoppedGracefully` is the
  /// conservative timing derivation agreed for the v1 wire contract.
  static func stop(id: String, timeoutSeconds: Int32) async throws -> [String: Any] {
    let client = ContainerClient()
    let snapshot = try await client.get(id: id)
    let wasStopped = snapshot.status == .stopped
    let started = ContinuousClock.now
    try await client.stop(
      id: id,
      opts: ContainerStopOptions(timeoutInSeconds: timeoutSeconds, signal: nil)
    )
    let elapsed = started.duration(to: ContinuousClock.now)
    let stoppedGracefully =
      wasStopped || (timeoutSeconds > 0 && elapsed < .seconds(Int64(timeoutSeconds)))
    return ["id": id, "stoppedGracefully": stoppedGracefully]
  }

  /// Force deletes running containers, but never bypasses the stopping state.
  static func delete(id: String, force: Bool) async throws -> [String: Any] {
    let client = ContainerClient()
    let snapshot = try await client.get(id: id)
    if snapshot.status == .stopping {
      throw NSError(
        domain: "container_bridge",
        code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "container \(id) is stopping; wait for it to stop"
        ]
      )
    }
    if snapshot.status == .running && !force {
      throw NSError(
        domain: "container_bridge",
        code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "container \(id) is running; stop it or use force"
        ]
      )
    }
    try await client.delete(id: id, force: force)
    return ["id": id]
  }

  static func kill(id: String, signal: String) async throws -> [String: Any] {
    let client = ContainerClient()
    try await client.kill(id: id, signal: signal)
    let snapshot = try await client.get(id: id)
    return ["id": id, "signal": signal, "status": snapshot.status.rawValue]
  }
}

/// One `container.logs` event-stream session: wires the two FileHandles
/// returned by `ContainerClient.logs(id:)` (fhs[0] = stdio, fhs[1] = boot)
/// to the Flutter event sink via `readabilityHandler`.
///
/// Event payloads sent to Dart:
/// - data:  {"stream": "container.logs", "id": ..., "source": "stdio"|"boot",
///           "data": FlutterStandardTypedData(bytes)}
/// - eof:   {"stream": "container.logs", "id": ..., "event": "eof"}
///   (sent once both handles hit EOF, followed by FlutterEndOfEventStream)
/// - error: {"stream": "container.logs", "id": ..., "event": "error",
///           "message": ...}
final class ContainerLogStreamSession {
  let containerId: String
  private let sink: FlutterEventSink
  private var handles: [(source: String, handle: FileHandle)] = []
  private var openHandles = 0
  private var finished = false

  /// Called on the main queue once the stream ended (eof or error), so the
  /// plugin can drop the session from its registry.
  var onFinish: ((ContainerLogStreamSession) -> Void)?

  init(containerId: String, sink: @escaping FlutterEventSink) {
    self.containerId = containerId
    self.sink = sink
  }

  func start() {
    Task {
      do {
        let fhs = try await ContainerClient().logs(id: containerId)
        await MainActor.run {
          // fhs[0] = stdio, fhs[1] = boot (container logs implementation).
          if !fhs.isEmpty { attach(source: "stdio", handle: fhs[0]) }
          if fhs.count > 1 { attach(source: "boot", handle: fhs[1]) }
          if fhs.isEmpty { finishAll() }
        }
      } catch {
        await MainActor.run {
          self.finished = true
          self.emit(["event": "error", "message": error.localizedDescription])
          self.endStream()
          self.onFinish?(self)
        }
      }
    }
  }

  /// Detaches handlers and closes the log handles (event-channel onCancel).
  func cancel() {
    for entry in handles {
      entry.handle.readabilityHandler = nil
      try? entry.handle.close()
    }
    handles = []
  }

  private func attach(source: String, handle: FileHandle) {
    handles.append((source, handle))
    openHandles += 1
    handle.readabilityHandler = { [weak self] fh in
      let data = fh.availableData
      guard let self else { return }
      DispatchQueue.main.async {
        if data.isEmpty {
          self.handleEof(fh)
        } else {
          self.emit([
            "source": source,
            "data": FlutterStandardTypedData(bytes: data),
          ])
        }
      }
    }
  }

  /// Must run on the main queue.
  private func handleEof(_ handle: FileHandle) {
    handle.readabilityHandler = nil
    try? handle.close()
    openHandles -= 1
    if openHandles <= 0 { finishAll() }
  }

  /// Must run on the main queue.
  private func finishAll() {
    guard !finished else { return }
    finished = true
    emit(["event": "eof"])
    endStream()
    onFinish?(self)
  }

  private func emit(_ extra: [String: Any]) {
    var payload: [String: Any] = ["stream": "container.logs", "id": containerId]
    payload.merge(extra) { _, new in new }
    sink(payload)
  }

  private func endStream() {
    sink(FlutterEndOfEventStream)
  }
}
