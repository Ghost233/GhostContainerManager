import Foundation

/// Result of one CLI invocation, mirrored by the Dart
/// `BridgeCommandResult.fromMap` on the app side.
struct CliResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool

  var asDictionary: [String: Any] {
    [
      "exitCode": Int(exitCode),
      "stdout": stdout,
      "stderr": stderr,
      "timedOut": timedOut,
    ]
  }
}

/// Thin `container` CLI runner.
///
/// stdout and stderr are drained concurrently on separate queues through a
/// DispatchGroup: a naive `readDataToEndOfFile()` on one pipe can deadlock
/// once the other pipe's 64 KB buffer fills.
///
/// The runner NEVER infers flags: callers pass the full argument vector
/// (e.g. system start always carries an explicit --enable/--disable-
/// kernel-install, otherwise the CLI blocks on readLine and dies with
/// "failed to read user input").
enum CliRunner {
  /// Locates the `container` binary: custom path first, then the two
  /// well-known install locations. Returns nil when not installed.
  static func locateBinary(customPath: String? = nil) -> String? {
    let candidates = [
      customPath,
      "/usr/local/bin/container",
      "/opt/homebrew/bin/container",
    ].compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// Runs `container` with [arguments]; finishes with a CliResult exactly
  /// once (completion or timeout, whichever first).
  static func run(
    binary: String,
    arguments: [String],
    timeout: TimeInterval = 60,
    completion: @escaping (CliResult) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: binary)
      process.arguments = arguments
      // Never inherit a TTY: interactive prompts must fail, not hang.
      process.standardInput = FileHandle.nullDevice

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      let group = DispatchGroup()
      var stdoutData = Data()
      var stderrData = Data()
      let stdoutHandle = stdoutPipe.fileHandleForReading
      let stderrHandle = stderrPipe.fileHandleForReading
      group.enter()
      DispatchQueue.global().async {
        stdoutData = stdoutHandle.readDataToEndOfFile()
        group.leave()
      }
      group.enter()
      DispatchQueue.global().async {
        stderrData = stderrHandle.readDataToEndOfFile()
        group.leave()
      }

      do {
        try process.run()
      } catch {
        completion(
          CliResult(
            exitCode: -1,
            stdout: "",
            stderr: "failed to launch \(binary): \(error.localizedDescription)",
            timedOut: false
          )
        )
        return
      }

      let deadline = DispatchTime.now() + timeout
      let finished = DispatchGroup()
      finished.enter()
      process.terminationHandler = { _ in finished.leave() }

      let waitResult = finished.wait(timeout: deadline)
      let timedOut = waitResult == .timedOut
      if timedOut {
        process.terminate()
      }
      // Drain whatever was written up to termination.
      _ = group.wait(timeout: .now() + 5)

      completion(
        CliResult(
          exitCode: timedOut ? -1 : process.terminationStatus,
          stdout: String(data: stdoutData, encoding: .utf8) ?? "",
          stderr: String(data: stderrData, encoding: .utf8) ?? "",
          timedOut: timedOut
        )
      )
    }
  }
}
