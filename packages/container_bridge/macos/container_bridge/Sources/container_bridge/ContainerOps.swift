import ContainerAPIClient
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
