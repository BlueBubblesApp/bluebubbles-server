//  BBError
//  The root error protocol. Its whole job is to make "should the user see this?"
//  an explicit property of the error rather than a side effect of logging it.
//
//  See `.claude/docs/architecture.md` — Diagnostics: logs are not notifications.

import Foundation

/// Severity of a condition, shared by the logging and alerting paths.
public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
  case info
  case success
  case warning
  case error
  case critical

  private var rank: Int {
    switch self {
    case .info: 0
    case .success: 1
    case .warning: 2
    case .error: 3
    case .critical: 4
    }
  }

  public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// A typed value attached to an error or alert for debugging.
///
/// `.secret` exists so redaction is structural rather than a thing each call site has to
/// remember. Anything sourced from a setting marked `isSecret` is wrapped in it, and it
/// renders as `••••` in the UI, in API responses, and in exported diagnostic reports.
public enum DiagnosticValue: Sendable, Equatable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case secret

  public var redactedDescription: String {
    switch self {
    case .string(let value): value
    case .int(let value): String(value)
    case .double(let value): String(value)
    case .bool(let value): String(value)
    case .secret: "••••"
    }
  }
}

/// Errors that opt into structured handling.
///
/// Conformance does not imply the user ever sees it — `isUserFacing` decides that, and the
/// default is `false`. Surfacing is always an explicit `AlertCenter.raise(_:)` call, never a
/// consequence of `logger.error(...)`.
public protocol BBError: Error, Sendable {
  /// Stable machine-readable identifier, e.g. `"helper.not_connected"`.
  /// Stable across releases so it can be searched, filtered, and referenced in issues.
  var code: String { get }

  /// Subsystem this originated in, e.g. `"PrivateAPI"`.
  var domain: String { get }

  var severity: Severity { get }

  /// Whether this condition warrants a user-visible notification. Most errors are noise
  /// to everyone but a developer reading logs, so this defaults to `false`.
  var isUserFacing: Bool { get }

  /// Short human title, used when this is surfaced. Not a stack trace, not a code.
  var title: String { get }

  /// One or two sentences a non-developer can act on.
  var body: String { get }

  /// Structured context. Secrets belong here as `.secret`, never as `.string`.
  var context: [String: DiagnosticValue] { get }
}

extension BBError {
  public var severity: Severity { .error }
  public var isUserFacing: Bool { false }
  public var context: [String: DiagnosticValue] { [:] }
}

public enum DiagnosticText {
  /// The most human-readable sentence an arbitrary error can offer.
  ///
  /// `BBError.body` first: the protocol requires it to be a sentence a non-developer can act
  /// on, so it beats anything that could be inferred. `LocalizedError` next, for types that
  /// wrote an explanation without adopting `BBError`. `String(describing:)` last, because on
  /// an enum it renders the CASE — `scriptFailed(number: -1728, …)`, escaped quotes and all —
  /// which reads to a reader like a crash rather than like the clear explanation it contains.
  ///
  /// A static on the protocol rather than a free function so it has an obvious home, and in
  /// BBCore rather than in the HTTP layer because the question "what does this error say" is
  /// not a transport question. `ErrorRenderer.message(for:)` and the interfaces layer both
  /// answer it, and two rules for one question would drift.
  public static func sentence(for error: any Error) -> String {
    if let bbError = error as? any BBError, !bbError.body.isEmpty { return bbError.body }
    if let localized = (error as? any LocalizedError)?.errorDescription { return localized }
    return String(describing: error)
  }
}
