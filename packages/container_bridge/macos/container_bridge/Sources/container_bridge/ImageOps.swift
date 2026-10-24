import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import FlutterMacOS
import Foundation
import TerminalProgress

/// Image-domain XPC operations (`ClientImage` over the dedicated
/// `com.apple.container.core.container-core-images` XPC service — NOT routed
/// through the apiserver; see docs/research/bridge-flutter-apple-container.md).
///
/// As with ContainerOps, this layer only executes and returns raw payloads;
/// all interpretation (dangling detection, in-use pre-check, error
/// classification) lives in the Dart Service layer (E02).
enum ImageOps {
  /// `ClientImage.list()` — unfiltered ImageDescription maps. `sizeBytes` is
  /// the index descriptor size (a lower bound; orchard shows it in list rows
  /// and computes the accurate size lazily). `createdAt` comes from the
  /// OCI `org.opencontainers.image.created` annotation when present.
  static func list() async throws -> [[String: Any]] {
    let images = try await ClientImage.list()
    return images.map { descriptionMap($0.description) }
  }

  /// Channel shape consumed by `ImageInfo.fromMap` on the Dart side.
  static func descriptionMap(_ description: ImageDescription) -> [String: Any] {
    var map: [String: Any] = [
      "reference": description.reference,
      "digest": description.digest,
      "mediaType": description.mediaType,
      "sizeBytes": description.descriptor.size,
    ]
    if let created = description.descriptor.annotations?["org.opencontainers.image.created"] {
      map["createdAt"] = created
    }
    return map
  }

  /// Config summary for `image_inspect`: index platforms, layer count from
  /// the current-platform manifest, and the OCI image config (env /
  /// entrypoint / cmd / exposedPorts / labels). `sizeBytes` is the accurate
  /// full size (blobs summed), falling back to the descriptor size.
  static func inspect(reference: String) async throws -> [String: Any] {
    let systemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
    let image = try await ClientImage.get(reference: reference, containerSystemConfig: systemConfig)
    let index = try await image.index()
    let platforms = index.manifests.compactMap { $0.platform?.description }
    let manifest = try await image.manifest(for: .current)
    let ociImage = try await image.config(for: .current)
    let sizeBytes =
      (try? await ClientImage.getFullImageSize(image: image)) ?? image.description.descriptor.size
    // Encode the OCI config generically: the concrete Swift field types vary
    // across containerization releases, the JSON shape is what Dart consumes.
    var configObject: [String: Any] = [:]
    if let config = ociImage.config,
      let data = try? JSONEncoder().encode(config),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      configObject = object
    }
    return [
      "reference": image.description.reference,
      "digest": image.description.digest,
      "sizeBytes": sizeBytes,
      "layers": manifest.layers.count,
      "platforms": platforms,
      "config": [
        // Containerization encodes OCI config keys capitalized ("Env",
        // "Labels"); accept both cases so Dart sees a stable lowercase shape.
        "env": configObject["env"] ?? configObject["Env"] ?? [String](),
        "entrypoint": configObject["entrypoint"] ?? configObject["Entrypoint"] ?? [String](),
        "cmd": configObject["cmd"] ?? configObject["Cmd"] ?? [String](),
        "exposedPorts":
          configObject["exposedPorts"] ?? configObject["ExposedPorts"] ?? [String](),
        "labels": configObject["labels"] ?? configObject["Labels"] ?? [String: String](),
      ],
    ]
  }

  /// `ClientImage.delete(reference:garbageCollect: false)` — removes the tag;
  /// unreferenced blobs are reclaimed by the runtime's own GC cadence.
  static func delete(reference: String) async throws {
    try await ClientImage.delete(reference: reference)
  }

  /// `ClientImage.pull` with a progress handler. Cancellation has no
  /// server-side route (v1): the plugin cancels the local waiting Task and
  /// reports `cancelled` to Dart; the runtime may finish the pull in the
  /// background.
  static func pull(
    reference: String,
    platform: Platform?,
    progress: @escaping ProgressUpdateHandler
  ) async throws -> ImageDescription {
    let systemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
    let image = try await ClientImage.pull(
      reference: reference,
      platform: platform,
      containerSystemConfig: systemConfig,
      progressUpdate: progress
    )
    return image.description
  }
}

/// Folds `ProgressUpdateEvent` batches into cumulative counters and emits
/// throttled (~10 Hz, orchard `ImagePullMetrics` precedent) payloads onto the
/// Flutter event channel. This is the single throttle point shared by the UI
/// progress bar and MCP progress notifications.
///
/// Payload shape consumed by `BridgeImagePullEvent.fromMap`:
/// `{pullId, description?, completedBytes, totalBytes?, itemsDone?, itemsTotal?}`.
actor PullProgressTracker {
  private let pullId: String
  private let emit: @Sendable ([String: Any]) -> Void

  private var detail: String?
  private var completedBytes: Int64 = 0
  private var totalBytes: Int64 = 0
  private var hasTotalBytes = false
  private var itemsDone = 0
  private var itemsTotal = 0
  private var lastEmit: ContinuousClock.Instant?

  init(pullId: String, emit: @escaping @Sendable ([String: Any]) -> Void) {
    self.pullId = pullId
    self.emit = emit
  }

  func consume(_ events: [ProgressUpdateEvent]) {
    var latestNote: String?
    for event in events {
      switch event {
      case .setDescription(let value):
        detail = value
      case .setSubDescription(let value):
        latestNote = value
      case .setItemsName:
        break
      case .addTasks(let count), .addTotalTasks(let count):
        itemsTotal += count
      case .setTasks(let count), .setTotalTasks(let count):
        itemsTotal = count
      case .addItems(let count):
        itemsDone += count
      case .setItems(let count):
        itemsDone = count
      case .addTotalItems(let count):
        itemsTotal += count
      case .setTotalItems(let count):
        itemsTotal = count
      case .addSize(let bytes):
        completedBytes += bytes
      case .setSize(let bytes):
        completedBytes = bytes
      case .addTotalSize(let bytes):
        totalBytes += bytes
        hasTotalBytes = true
      case .setTotalSize(let bytes):
        totalBytes = bytes
        hasTotalBytes = true
      case .custom(let value):
        latestNote = value
      }
    }
    if let latestNote { detail = latestNote }
    emitThrottled()
  }

  private func emitThrottled() {
    let now = ContinuousClock.now
    if let lastEmit, now - lastEmit < .milliseconds(100) { return }
    lastEmit = now
    var payload: [String: Any] = [
      "pullId": pullId,
      "completedBytes": completedBytes,
    ]
    if let detail { payload["description"] = detail }
    if hasTotalBytes { payload["totalBytes"] = totalBytes }
    if itemsTotal > 0 {
      payload["itemsDone"] = itemsDone
      payload["itemsTotal"] = itemsTotal
    }
    emit(payload)
  }
}
