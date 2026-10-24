import Darwin
import FlutterMacOS
import Foundation

/// A child process in its own process group, with two independently drained
/// pipes and stdin attached to /dev/null. posix_spawn is used because
/// Foundation.Process has no API to create a process group before exec.
final class CliChildProcess {
  let processIdentifier: pid_t
  let stdout: FileHandle
  let stderr: FileHandle

  private let stateLock = NSLock()
  private var reaped = false

  private init(processIdentifier: pid_t, stdout: FileHandle, stderr: FileHandle) {
    self.processIdentifier = processIdentifier
    self.stdout = stdout
    self.stderr = stderr
  }

  static func spawn(binary: String, arguments: [String]) throws -> CliChildProcess {
    let stdoutPipe = try makePipe()
    let stderrPipe = try makePipe()
    guard let nullInput = FileHandle(forReadingAtPath: "/dev/null") else {
      try? stdoutPipe.0.close()
      try? stdoutPipe.1.close()
      try? stderrPipe.0.close()
      try? stderrPipe.1.close()
      throw CliError.message("unable to open /dev/null")
    }
    defer {
      try? stdoutPipe.1.close()
      try? stderrPipe.1.close()
      try? nullInput.close()
    }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw CliError.message("posix_spawn_file_actions_init failed")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw CliError.message("posix_spawnattr_init failed")
    }
    defer { posix_spawnattr_destroy(&attributes) }

    let actionResults = [
      posix_spawn_file_actions_adddup2(&fileActions, nullInput.fileDescriptor, STDIN_FILENO),
      posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.1.fileDescriptor, STDOUT_FILENO),
      posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.1.fileDescriptor, STDERR_FILENO),
      posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.0.fileDescriptor),
      posix_spawn_file_actions_addclose(&fileActions, stderrPipe.0.fileDescriptor),
      posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.1.fileDescriptor),
      posix_spawn_file_actions_addclose(&fileActions, stderrPipe.1.fileDescriptor),
      posix_spawn_file_actions_addclose(&fileActions, nullInput.fileDescriptor),
    ]
    guard actionResults.allSatisfy({ $0 == 0 }) else {
      throw CliError.message("unable to configure CLI process pipes")
    }
    guard posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
      throw CliError.message("unable to configure CLI process group")
    }
    guard
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0
    else {
      throw CliError.message("unable to enable CLI process-group isolation")
    }

    let allocatedArguments = ([binary] + arguments).map { strdup($0) }
    defer {
      for argument in allocatedArguments { free(argument) }
    }
    var argv = allocatedArguments + [nil]
    var pid = pid_t()
    let spawnResult = posix_spawn(&pid, binary, &fileActions, &attributes, &argv, environ)
    guard spawnResult == 0 else {
      throw CliError.message("posix_spawn failed: \(String(cString: strerror(spawnResult)))")
    }
    return CliChildProcess(
      processIdentifier: pid,
      stdout: stdoutPipe.0,
      stderr: stderrPipe.0
    )
  }

  private static func makePipe() throws -> (FileHandle, FileHandle) {
    var descriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&descriptors) == 0 else {
      throw CliError.message("pipe failed: \(String(cString: strerror(errno)))")
    }
    return (
      FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
      FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    )
  }

  /// Blocks until the child exits. Called on a dedicated background queue.
  func wait() -> Int32 {
    var status = Int32()
    var result: pid_t
    repeat {
      result = waitpid(processIdentifier, &status, 0)
    } while result < 0 && errno == EINTR
    stateLock.lock()
    reaped = true
    stateLock.unlock()
    guard result == processIdentifier else { return -1 }
    if (status & 0x7f) == 0 {
      return (status >> 8) & 0xff
    }
    return 128 + (status & 0x7f)
  }

  /// Sends SIGTERM to the entire process group, not just the immediate child.
  func terminate() {
    signalGroup(SIGTERM)
  }

  /// Escalates a timed-out run after its SIGTERM grace period expires.
  func kill() {
    signalGroup(SIGKILL)
  }

  private func signalGroup(_ signal: Int32) {
    guard processIdentifier > 0 else { return }
    stateLock.lock()
    defer { stateLock.unlock() }
    // Never signal a process group after waitpid has reaped its leader.
    guard !reaped else { return }
    _ = Darwin.kill(-processIdentifier, signal)
  }
}

/// Incremental byte buffer: split only on LF, strip optional CR, and decode a
/// complete line as UTF-8 so multibyte characters may span arbitrary chunks.
struct CliLineBuffer {
  private var bytes: [UInt8] = []

  mutating func append(_ data: Data) -> [String] {
    bytes.append(contentsOf: data)
    var lines: [String] = []
    while let newline = bytes.firstIndex(of: 0x0a) {
      lines.append(Self.decode(Array(bytes[..<newline])))
      bytes.removeSubrange(...newline)
    }
    return lines
  }

  mutating func finish() -> String? {
    guard !bytes.isEmpty else { return nil }
    let line = Self.decode(bytes)
    bytes.removeAll()
    return line
  }

  private static func decode(_ bytes: [UInt8]) -> String {
    let line = bytes.last == 0x0d ? Array(bytes.dropLast()) : bytes
    return String(decoding: line, as: UTF8.self)
  }
}

/// Native side of one `cli.process` EventChannel. State is confined to the
/// main queue; output is buffered until Dart attaches its event sink.
final class CliStreamSession {
  private static let maximumPendingLines = 1000

  let handle: String
  var onFinish: ((CliStreamSession) -> Void)?
  private(set) var hasAttachedSink = false

  private var child: CliChildProcess?
  private var sink: FlutterEventSink?
  private var pendingEvents: [[String: Any]] = []
  private var pendingOutputLineCount = 0
  private var droppedOutputLineCount = 0
  private var openSources: Set<String> = []
  private var stdoutBuffer = CliLineBuffer()
  private var stderrBuffer = CliLineBuffer()
  private var pendingExitCode: Int32?
  private var finished = false
  private var cancelled = false

  init(handle: String) {
    self.handle = handle
  }

  /// Main queue. Throws synchronously if the process cannot be spawned.
  func start(binary: String, arguments: [String]) throws {
    let process = try CliChildProcess.spawn(binary: binary, arguments: arguments)
    child = process
    openSources = ["stdout", "stderr"]
    attach(handle: process.stdout, source: "stdout")
    attach(handle: process.stderr, source: "stderr")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let exitCode = process.wait()
      DispatchQueue.main.async {
        guard let self, !self.cancelled else { return }
        self.pendingExitCode = exitCode
        self.finishIfReady()
      }
    }
  }

  /// Main queue. Replays at most the latest 1000 buffered output lines. If
  /// older lines were dropped, an explicit stderr marker precedes the replay.
  func attachSink(_ sink: @escaping FlutterEventSink) {
    guard !cancelled else { return }
    hasAttachedSink = true
    self.sink = sink
    if droppedOutputLineCount > 0 {
      sink([
        "event": "stderr",
        "line": "[container_bridge] dropped \(droppedOutputLineCount) older "
          + "output line(s) before subscription; showing the latest "
          + "\(Self.maximumPendingLines) buffered lines.",
      ])
    }
    let events = pendingEvents
    pendingEvents.removeAll()
    pendingOutputLineCount = 0
    droppedOutputLineCount = 0
    for event in events { sink(event) }
    if finished {
      sink(FlutterEndOfEventStream)
      onFinish?(self)
    }
  }

  /// Main queue. Keeps readers attached so the terminal exit event can follow
  /// the final stdout/stderr lines.
  func terminate() {
    guard !cancelled, !finished else { return }
    child?.terminate()
  }

  /// Event-channel cancellation/dispose: terminate the group and release both
  /// descriptors immediately. The background waitpid still reaps the child.
  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    if !finished { child?.terminate() }
    detachReaders()
    pendingEvents.removeAll()
    sink = nil
  }

  private func attach(handle: FileHandle, source: String) {
    handle.readabilityHandler = { [weak self] fileHandle in
      let data = fileHandle.availableData
      if data.isEmpty { fileHandle.readabilityHandler = nil }
      DispatchQueue.main.async {
        guard let self, !self.cancelled else { return }
        if data.isEmpty {
          self.closeSource(source, handle: fileHandle)
        } else {
          self.consume(data, source: source)
        }
      }
    }
  }

  private func consume(_ data: Data, source: String) {
    let lines: [String]
    if source == "stdout" {
      lines = stdoutBuffer.append(data)
    } else {
      lines = stderrBuffer.append(data)
    }
    for line in lines { emit(["event": source, "line": line]) }
  }

  private func closeSource(_ source: String, handle: FileHandle) {
    guard openSources.remove(source) != nil else {
      try? handle.close()
      return
    }
    handle.readabilityHandler = nil
    if source == "stdout", let line = stdoutBuffer.finish() {
      emit(["event": source, "line": line])
    } else if source == "stderr", let line = stderrBuffer.finish() {
      emit(["event": source, "line": line])
    }
    try? handle.close()
    finishIfReady()
  }

  private func finishIfReady() {
    guard !finished, !cancelled, pendingExitCode != nil, openSources.isEmpty else {
      return
    }
    finished = true
    emit(["event": "exit", "exitCode": pendingExitCode ?? -1])
    if let sink { sink(FlutterEndOfEventStream) }
    // Completion must also release sessions whose Dart side never subscribed.
    onFinish?(self)
  }

  private func emit(_ event: [String: Any]) {
    guard !cancelled else { return }
    if let sink {
      sink(event)
      return
    }
    let kind = event["event"] as? String
    let isOutputLine = kind == "stdout" || kind == "stderr"
    if isOutputLine, pendingOutputLineCount >= Self.maximumPendingLines {
      guard
        let oldestOutput = pendingEvents.firstIndex(where: {
          let pendingKind = $0["event"] as? String
          return pendingKind == "stdout" || pendingKind == "stderr"
        })
      else { return }
      pendingEvents.remove(at: oldestOutput)
      droppedOutputLineCount += 1
    } else if isOutputLine {
      pendingOutputLineCount += 1
    }
    // The terminal exit event is never dropped, even at the output-line cap.
    pendingEvents.append(event)
  }

  private func detachReaders() {
    guard let child else { return }
    child.stdout.readabilityHandler = nil
    child.stderr.readabilityHandler = nil
    try? child.stdout.close()
    try? child.stderr.close()
    openSources.removeAll()
  }
}
