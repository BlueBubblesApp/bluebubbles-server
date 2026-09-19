//  ToolCommand
//  Running one command of an external tool to completion, and the four ways that fails.
//
//  zrok and Tailscale each wrapped `Subprocess` the same way: check the binary exists, run
//  it with merged output, map a timeout and a launch failure, refuse a non-zero exit, and
//  each declared the same four error cases with the tool's name in the sentence. One runner
//  and one error, with the tool named, so a third binary tunnel gets both by calling rather
//  than by copying.
//
//  Deliberately NOT `DaemonProcess`: that supervises a long-running tunnel, waits for a
//  readiness line, and restarts what dies. None of that applies to `zrok overview` or
//  `tailscale status`, and every one of those behaviours would be actively wrong for them.

import BBCore
import Foundation
import Logging

/// What running one command of an external tool can fail with.
///
/// `tool` is the name a person reads ("zrok", "Tailscale") and is also what prefixes the
/// diagnostic code, so a report says which tool without a second field.
public enum ToolCommandError: BBError, Equatable {
  case executableMissing(tool: String, path: String)
  case launchFailed(tool: String, reason: String)
  /// The command ran and failed. `output` is the tool's own words, which are the only
  /// useful explanation; "exit status 1" names nothing a user could act on.
  case commandFailed(tool: String, command: String, output: String)
  case timedOut(tool: String, command: String)

  public var message: String {
    switch self {
    case .executableMissing(let tool, let path):
      "the \(tool) program is missing at \(path)"
    case .launchFailed(_, let reason):
      reason
    case .commandFailed(let tool, _, let output):
      output.isEmpty ? "\(tool) failed without printing anything" : output
    case .timedOut(let tool, let command):
      "\(tool) \(command) did not finish in time"
    }
  }

  public var tool: String {
    switch self {
    case .executableMissing(let tool, _), .launchFailed(let tool, _),
      .commandFailed(let tool, _, _), .timedOut(let tool, _):
      tool
    }
  }

  public var code: String {
    let prefix = tool.lowercased()
    return switch self {
    case .executableMissing: "\(prefix).executable_missing"
    case .launchFailed: "\(prefix).launch_failed"
    case .commandFailed: "\(prefix).command_failed"
    case .timedOut: "\(prefix).timed_out"
    }
  }

  public var domain: String { "Proxy" }

  /// Every case is folded into `ProxyError.tunnelFailed` by the provider, whose message
  /// is what a person reads; this is what a diagnostic report carries for one caught on
  /// its own.
  public var title: String { "\(tool) reported a problem" }

  /// `message` already carries the tool's own words, which are the only useful explanation.
  public var body: String { message }
}

/// A subprocess that is expected to finish, as opposed to one that is expected to stay up.
public enum ToolCommand {

  public struct Result: Sendable, Equatable {
    public let output: String
    public let succeeded: Bool
    /// Killed by the backstop timeout, with its output lost. Only ever true when the
    /// caller asked to tolerate a timeout; otherwise a timeout throws.
    public let timedOut: Bool
  }

  /// Everything a finished command printed, or the error that stopped it.
  ///
  /// Output is drained CONCURRENTLY rather than read after the process exits. A pipe holds
  /// about 64KB, and `zrok overview` on an account with a few shares prints more than that;
  /// so waiting for the exit first would deadlock: the tool blocks writing into a full pipe
  /// nobody is reading, and we block waiting for a process that can never finish.
  /// `Subprocess` owns the draining, the timeout and the stdin detach.
  ///
  /// Merged output, because zrok puts its errors on one stream and its answers on the
  /// other, and which is which has moved between versions.
  ///
  /// - Parameters:
  ///   - tolerateFailure: Return a non-zero exit as a `Result` rather than throwing;
  ///     `tailscale status` exits non-zero while the node is down, and that is the answer.
  ///   - tolerateTimeout: Return a timeout as a `Result` rather than throwing.
  public static func run(
    tool: String,
    executablePath: String,
    arguments: [String],
    environment: [String: String] = [:],
    command: String,
    timeout: Duration,
    tolerateFailure: Bool = false,
    tolerateTimeout: Bool = false,
    logger: Logger? = nil
  ) async throws -> Result {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw ToolCommandError.executableMissing(tool: tool, path: executablePath)
    }
    let result: Subprocess.Result
    do {
      result = try await Subprocess.run(
        executablePath, arguments,
        environment: environment,
        output: .merged,
        timeout: timeout
      )
    } catch let failure as Subprocess.Failure {
      switch failure {
      case .timedOut:
        if tolerateTimeout {
          return Result(output: "", succeeded: false, timedOut: true)
        }
        throw ToolCommandError.timedOut(tool: tool, command: command)
      case .launchFailed(_, let reason):
        throw ToolCommandError.launchFailed(tool: tool, reason: reason)
      }
    }
    let output = result.trimmedText
    logger?.trace(
      "\(tool) command finished",
      metadata: [
        "command": .string(command),
        "status": .stringConvertible(result.status),
      ])
    guard result.succeeded || tolerateFailure else {
      throw ToolCommandError.commandFailed(tool: tool, command: command, output: output)
    }
    return Result(output: output, succeeded: result.succeeded, timedOut: false)
  }
}
