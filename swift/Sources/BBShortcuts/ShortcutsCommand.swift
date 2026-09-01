//  ShortcutsCommand
//  The `/usr/bin/shortcuts` boundary.
//
//  A protocol for the same reason `ProcessRunning`, `PermissionProbing` and
//  `AppleScriptRunning` are: it is where this server stops and something outside it begins.
//  Everything interesting about the group-chat path — what "installed" means, how a run
//  failure is reported, what happens when the user deletes the shortcut behind our back — is
//  decided by what this returns, and none of it is reachable in a test against the real CLI.
//
//  What the CLI can and cannot do, measured on macOS 26.5.2:
//
//    `shortcuts list`   — names, one per line. The ONLY detection mechanism there is.
//    `shortcuts run`    — runs one, optionally with `-i <file>` as input.
//    `shortcuts sign`   — signs a workflow plist so it can be imported.
//    (no `add`)         — importing is `open`, which shows a sheet the USER must confirm.
//    (no `delete`)      — removing is a person, in the Shortcuts app. See `Uninstall`.
//
//  Those two absences shape the whole feature: installation and removal are user gestures we
//  can only start and then observe, never perform.

import BBCore
import Foundation

/// What one run of the CLI produced.
public struct ShortcutRunResult: Sendable, Equatable {
  public let succeeded: Bool
  /// Whatever the CLI printed. Nearly always useless — see `ShortcutsError.runFailed`.
  public let output: String

  public init(succeeded: Bool, output: String) {
    self.succeeded = succeeded
    self.output = output
  }
}

public enum ShortcutsError: BBError, Equatable {
  /// The CLI is missing. Should not happen on a supported system; reported rather than
  /// trapped so a stripped install degrades to a clear message.
  case commandUnavailable
  /// `shortcuts run` exited non-zero.
  ///
  /// **The output is very nearly always the literal string "An unknown error occurred."**
  /// Measured across every failure mode probed: a missing permission grant, a malformed
  /// recipients parameter, and a recipient set Messages simply refused all produce that
  /// same sentence and the same exit code. There is no diagnostic channel here — no error
  /// number, no per-action detail, nothing in `log stream`. Callers must NOT try to
  /// classify a failure from this text; the only honest report is that it did not work.
  case runFailed(output: String)
  case signingFailed(output: String)
  /// The workflow could not be serialized. A programming error, not a user-facing one.
  case definitionInvalid(reason: String)
  /// A copy is already in the library, and importing a second would break both.
  ///
  /// The Shortcuts import does not replace by name — it adds — and the CLI addresses
  /// shortcuts only by name, so two identical entries make every run fail with "Couldn't
  /// find shortcut". Measured, not assumed.
  case alreadyInstalled
}

/// Runs the Shortcuts CLI.
public protocol ShortcutsCommanding: Sendable {
  /// Every shortcut name in the user's library.
  func list() async throws -> [String]
  /// Runs one by name, with an optional input file.
  func run(name: String, inputPath: String?) async throws -> ShortcutRunResult
  /// Signs `input` into `output` so the Shortcuts app will accept the import.
  func sign(input: String, output: String) async throws
}

public struct ShortcutsCommand: ShortcutsCommanding {

  private let executable: String

  public init(executable: String = "/usr/bin/shortcuts") {
    self.executable = executable
  }

  public func list() async throws -> [String] {
    let result = try await execute(["list"], timeout: .seconds(20))
    guard result.succeeded else { throw ShortcutsError.commandUnavailable }
    return result.text
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// - Parameter timeout: Generous, and deliberately so. A run whose permission has not yet
  ///   been granted BLOCKS on the approval sheet — measured at 63 seconds before the CLI
  ///   gave up on its own. That is the first-run case the setup flow exists to walk a user
  ///   through, so the deadline has to outlast a person reading a dialog and deciding.
  public func run(name: String, inputPath: String?) async throws -> ShortcutRunResult {
    var arguments = ["run", name]
    if let inputPath { arguments.append(contentsOf: ["-i", inputPath]) }
    let result = try await execute(arguments, timeout: .seconds(180))
    return ShortcutRunResult(succeeded: result.succeeded, output: result.trimmedText)
  }

  public func sign(input: String, output: String) async throws {
    // `--mode anyone` rather than `people-who-know-me`: the signature exists so the import
    // sheet accepts the file at all, not to attest anything about its origin. A shortcut
    // signed for a specific iCloud account cannot be imported on the Mac that generated it
    // under a different account, which is exactly the support case we do not want.
    let result = try await execute(
      ["sign", "--mode", "anyone", "--input", input, "--output", output],
      timeout: .seconds(60)
    )
    guard result.succeeded else {
      throw ShortcutsError.signingFailed(output: result.trimmedText)
    }
  }

  private func execute(_ arguments: [String], timeout: Duration) async throws -> Subprocess.Result {
    do {
      return try await Subprocess.run(
        executable, arguments, output: .merged, timeout: timeout
      )
    } catch let failure as Subprocess.Failure {
      switch failure {
      case .launchFailed: throw ShortcutsError.commandUnavailable
      case .timedOut: throw ShortcutsError.runFailed(output: "timed out")
      }
    }
  }
}

extension ShortcutsError {
  public var code: String {
    switch self {
    case .commandUnavailable: "shortcuts.command_unavailable"
    case .runFailed: "shortcuts.run_failed"
    case .signingFailed: "shortcuts.signing_failed"
    case .definitionInvalid: "shortcuts.definition_invalid"
    case .alreadyInstalled: "shortcuts.already_installed"
    }
  }

  public var domain: String { "Messaging" }

  public var isUserFacing: Bool {
    switch self {
    case .commandUnavailable, .runFailed: true
    default: false
    }
  }

  public var title: String { "A Shortcut could not run" }

  public var body: String {
    switch self {
    case .commandUnavailable:
      "The Shortcuts command line tool is not available on this Mac."
    case .runFailed:
      // Deliberately does not quote the CLI's output: it is "An unknown error occurred."
      // in every case, and repeating it to a user reads as a bug in this app.
      """
      The BlueBubbles group chat Shortcut did not complete. Open Settings and run the test \
      message again to confirm it is still installed and permitted.
      """
    case .signingFailed(let output):
      "The Shortcut could not be signed for installation. \(output)"
    case .definitionInvalid(let reason):
      "The Shortcut definition could not be built: \(reason)"
    case .alreadyInstalled:
      """
      A copy of this Shortcut is already installed. Remove it in the Shortcuts app first — \
      installing a second copy with the same name stops both from running.
      """
    }
  }
}
