import ContainerAPIClient
import ContainerResource
import Foundation

/// One-shot, non-TTY exec over ContainerClient XPC. stdout and stderr are
/// drained independently and capped before crossing the Flutter channel.
enum ExecOps {
  private static let outputLimit = 64 * 1024

  static func run(
    id: String,
    command: [String],
    env: [String],
    workdir: String?,
    user: String?,
    timeoutSeconds: Int
  ) async throws -> [String: Any] {
    guard !id.isEmpty, let executable = command.first, !executable.isEmpty,
      (1...600).contains(timeoutSeconds)
    else {
      throw ExecError.invalidArgument("exec requires a container, command, and 1...600 second timeout")
    }

    let client = ContainerClient()
    let snapshot = try await client.get(id: id)
    guard snapshot.status == .running else {
      throw ExecError.notRunning("container \(id) is not running")
    }

    var configuration = snapshot.configuration.initProcess
    configuration.executable = executable
    configuration.arguments = Array(command.dropFirst())
    configuration.terminal = false
    configuration.environment = try mergedEnvironment(
      configuration.environment,
      overrides: env
    )
    if let workdir { configuration.workingDirectory = workdir }
    if let user { configuration.user = .raw(userString: user) }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let process = try await client.createProcess(
      containerId: id,
      processId: UUID().uuidString.lowercased(),
      configuration: configuration,
      stdio: [
        FileHandle.nullDevice,
        stdoutPipe.fileHandleForWriting,
        stderrPipe.fileHandleForWriting,
      ]
    )

    do {
      try await process.start()
    } catch {
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      try? stdoutPipe.fileHandleForReading.close()
      try? stderrPipe.fileHandleForReading.close()
      throw error
    }

    // The XPC service owns its duplicates. Closing the local writers is
    // required for the readers to observe EOF when the process exits.
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()
    let stdout = BoundedExecOutput(limit: outputLimit)
    let stderr = BoundedExecOutput(limit: outputLimit)
    stdout.start(stdoutPipe.fileHandleForReading)
    stderr.start(stderrPipe.fileHandleForReading)

    let race = ExecWaitRace()
    let waitTask = Task {
      do {
        race.complete(.exited(try await process.wait()))
      } catch {
        race.complete(.failed(error.localizedDescription))
      }
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
        race.complete(.timedOut)
      } catch {
        // Normal process completion cancels this timer.
      }
    }

    let outcome = await race.wait()
    timeoutTask.cancel()
    switch outcome {
    case .exited(let exitCode):
      // A child can inherit a pipe and outlive the requested command. Bound
      // the post-exit drain instead of waiting forever for that descendant.
      async let stdoutDrained = stdout.wait(timeout: 3)
      async let stderrDrained = stderr.wait(timeout: 3)
      _ = await (stdoutDrained, stderrDrained)
      return payload(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        timedOut: false
      )
    case .timedOut:
      // Cancellation of an XPC wait is not a reliable timeout boundary. Leave
      // its unstructured task alone, abandon the wait, and signal on a best-
      // effort basis: upstream apple/container#1941 may leave the process alive.
      waitTask.cancel()
      Task { try? await process.kill(SIGKILL) }
      stdout.finish()
      stderr.finish()
      return payload(exitCode: -1, stdout: stdout, stderr: stderr, timedOut: true)
    case .failed(let message):
      waitTask.cancel()
      stdout.finish()
      stderr.finish()
      throw ExecError.waitFailed(message)
    }
  }

  private static func mergedEnvironment(_ inherited: [String], overrides: [String]) throws -> [String] {
    var merged = inherited
    for entry in overrides {
      guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
        throw ExecError.invalidArgument("environment overrides must use KEY=VALUE")
      }
      let key = entry[..<separator]
      if let index = merged.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
        merged[index] = entry
      } else {
        merged.append(entry)
      }
    }
    return merged
  }

  private static func payload(
    exitCode: Int32,
    stdout: BoundedExecOutput,
    stderr: BoundedExecOutput,
    timedOut: Bool
  ) -> [String: Any] {
    [
      "exitCode": Int(exitCode),
      "stdout": stdout.text,
      "stderr": stderr.text,
      "stdoutTruncated": stdout.truncated,
      "stderrTruncated": stderr.truncated,
      "timedOut": timedOut,
    ]
  }
}

private enum ExecError: LocalizedError {
  case invalidArgument(String)
  case notRunning(String)
  case waitFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let message), .notRunning(let message), .waitFailed(let message):
      message
    }
  }
}

private enum ExecWaitOutcome {
  case exited(Int32)
  case timedOut
  case failed(String)
}

/// Single-resume race between process exit and the caller's deadline. The
/// process wait is deliberately unstructured so timeout does not depend on
/// XPC cancellation propagating through ClientProcess.wait().
private final class ExecWaitRace: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome: ExecWaitOutcome?
  private var continuation: CheckedContinuation<ExecWaitOutcome, Never>?

  func complete(_ value: ExecWaitOutcome) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = value
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume(returning: value)
  }

  func wait() async -> ExecWaitOutcome {
    await withCheckedContinuation { waiting in
      lock.lock()
      if let outcome {
        lock.unlock()
        waiting.resume(returning: outcome)
      } else {
        continuation = waiting
        lock.unlock()
      }
    }
  }
}

/// Thread-safe, always-draining capture. Excess bytes are discarded rather
/// than left in a full pipe, which would deadlock the container process.
private final class BoundedExecOutput: @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var bytes = Data()
  private var wasTruncated = false
  private var handle: FileHandle?
  private var finished = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(limit: Int) {
    self.limit = limit
  }

  var text: String {
    lock.lock()
    let snapshot = bytes
    lock.unlock()
    return String(decoding: snapshot, as: UTF8.self)
  }

  var truncated: Bool {
    lock.lock()
    let value = wasTruncated
    lock.unlock()
    return value
  }

  func start(_ handle: FileHandle) {
    lock.lock()
    self.handle = handle
    lock.unlock()
    handle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        self?.finish()
      } else {
        self?.append(data)
      }
    }
  }

  func wait(timeout: TimeInterval) async {
    await withCheckedContinuation { waiting in
      lock.lock()
      if finished {
        lock.unlock()
        waiting.resume()
        return
      }
      continuation = waiting
      lock.unlock()
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.finish()
      }
    }
  }

  func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let waiting = continuation
    continuation = nil
    let current = handle
    handle = nil
    lock.unlock()
    current?.readabilityHandler = nil
    try? current?.close()
    waiting?.resume()
  }

  private func append(_ data: Data) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    let remaining = limit - bytes.count
    if remaining > 0 {
      bytes.append(data.prefix(remaining))
    }
    if data.count > remaining {
      wasTruncated = true
    }
    lock.unlock()
  }
}
