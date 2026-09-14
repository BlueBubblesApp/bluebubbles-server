//  ToolVersionProbe
//  Running a program to ask which version it is, and reading the answer.
//
//  One parser and one runner, shared by the two callers that must agree about them. The
//  installer probes a build it has just downloaded, as the smoke test that turns a
//  wrong-architecture download into a clear message instead of a tunnel that fails hours
//  later. Discovery probes a copy that was already on the Mac, where the answer is not a smoke
//  test but the whole basis for using the thing.
//
//  They differ in what they do with the answer, not in how they get it, and that is why this
//  is one file: two parsers that must agree is two parsers that will not.

import BBCore
import BBServiceKit
import Foundation

/// What happened when a binary was asked its version.
///
/// Three outcomes rather than an optional, because the difference between them decides
/// whether a copy is used. "It printed something we could not read" is a working program with
/// an unexpected format; "it would not start" is usually the wrong architecture. Collapsing
/// those into `nil` loses the only information a person could act on.
public enum ProbeOutcome: Sendable, Codable, Equatable {
  case ran(version: String)
  /// It ran and printed nothing a version could be read out of.
  case versionUnreadable
  /// It would not start, or would not answer. Carries the sentence, already written for a
  /// person by `Subprocess.Failure`.
  case wouldNotRun(reason: String)

  public var version: String? {
    if case .ran(let version) = self { return version }
    return nil
  }
}

enum ToolVersionProbe {

  /// Runs the binary and reads a version out of what it says.
  ///
  /// Never throws: every outcome is one of the three above. The installer turns
  /// `.wouldNotRun` into `ToolError.versionProbeFailed` because at that point it is refusing
  /// an install; discovery turns it into "skip this candidate and try the next prefix".
  static func run(
    _ descriptor: ManagedToolDescriptor, executable: String
  ) async -> ProbeOutcome {
    let result: Subprocess.Result
    do {
      result = try await Subprocess.run(
        executable, descriptor.versionProbe.arguments,
        output: .merged,
        timeout: .seconds(descriptor.versionProbe.timeoutSeconds)
      )
    } catch let failure as Subprocess.Failure {
      // A LAUNCH failure is where a wrong-architecture binary surfaces: `posix_spawn`
      // reports "Bad CPU type in executable" before anything runs. A TIMEOUT is a binary
      // that decided to wait for input or phone home.
      return .wouldNotRun(reason: failure.body)
    } catch {
      return .wouldNotRun(reason: String(describing: error))
    }
    // The exit status is deliberately not checked: a tool that ran and printed something
    // unexpected has passed the check that matters, which is that it EXECUTED.
    guard let version = version(in: result.text) else { return .versionUnreadable }
    return .ran(version: version)
  }

  /// The first version-looking token in a line of output.
  ///
  /// `ngrok version 3.18.4`, `cloudflared version 2024.8.2 (built …)`, `zrok v1.0.4`: all
  /// answered by finding the first dotted number rather than by a pattern per vendor, which
  /// would be one more thing to maintain per tool for no gain.
  static func version(in output: String) -> String? {
    var current = ""
    for character in output {
      if character.isNumber || character == "." {
        current.append(character)
      } else {
        if current.contains("."), current.first?.isNumber == true {
          return current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        current = ""
      }
    }
    if current.contains("."), current.first?.isNumber == true {
      return current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    return nil
  }
}
