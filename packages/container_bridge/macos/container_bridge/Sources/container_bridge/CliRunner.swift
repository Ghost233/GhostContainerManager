import Foundation

/// Non-zero exit is data (the CLI's business), not a thrown error.
/// Thrown errors = process-level failures only (binary missing, cannot launch).
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

enum CliError: LocalizedError, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let text): return text
    }
  }

  var errorDescription: String? { description }
}

/// CLI runner. PATH probing is explicit (no shell): Flutter Release strips
/// the user's login PATH, so we probe known Apple container locations.
enum CliRunner {
  static func locateBinary(customPath: String? = nil) -> String? {
    let candidates = [
      customPath,
      "/usr/local/bin/container",
      "/opt/homebrew/bin/container",
    ].compactMap { $0 }
    let fm = FileManager.default
    for path in candidates where fm.isExecutableFile(atPath: path) {
      return path
    }
    return nil
  }

  /// Execute `container <arguments>` without a shell. stdin = nullDevice.
  /// stdout and stderr are drained concurrently; timeout terminates the whole
  /// isolated process group. The completion runs on a background queue;
  /// callers hop to MainActor/main queue before touching FlutterResult.
  static func run(
    binary: String,
    arguments: [String],
    timeout: TimeInterval = 60,
    completion: @escaping (CliResult) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let process = try CliChildProcess.spawn(binary: binary, arguments: arguments)
        let ioQueue = DispatchQueue(label: "gcm.cli.io", attributes: .concurrent)
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        var terminationStatus = Int32(-1)

        group.enter()
        ioQueue.async {
          stdoutData = process.stdout.readDataToEndOfFile()
          try? process.stdout.close()
          group.leave()
        }
        group.enter()
        ioQueue.async {
          stderrData = process.stderr.readDataToEndOfFile()
          try? process.stderr.close()
          group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          terminationStatus = process.wait()
          group.leave()
        }

        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
          process.terminate()
          if group.wait(timeout: .now() + 2) == .timedOut {
            // Stubborn children may ignore SIGTERM; never leave the group up.
            process.kill()
          }
        }
        // Drain whatever was written up to termination or SIGKILL escalation.
        _ = group.wait(timeout: .now() + 5)

        completion(
          CliResult(
            exitCode: timedOut ? -1 : terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
          )
        )
      } catch {
        completion(
          CliResult(
            exitCode: -1,
            stdout: "",
            stderr: "failed to launch \(binary): \(error.localizedDescription)",
            timedOut: false
          )
        )
      }
    }
  }
}
