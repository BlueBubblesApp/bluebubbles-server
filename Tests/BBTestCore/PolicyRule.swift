//  PolicyRule
//  What a source-scanning policy test says when it fails, in one shape.
//
//  A policy test's failure lists its offenders as `path:line: text`, which is enough to find
//  the line and nothing more. The reader is usually an agent, mid-task, and it acts on the
//  message without opening the test: with only the offender it guesses at the rule, guesses
//  at the fix, and cannot tell whether the rule is one it is allowed to argue with. Each test
//  used to carry its own wrapper sentence, some helpful, most a fragment, and none naming
//  where the rule is written down.
//
//  So every policy failure carries three things before its offenders, and this type is the
//  one place that decides the order and the wording of the frame:
//
//  - the RULE, one sentence saying what must or must not happen, so the reader knows what
//    was broken;
//  - the FIX, one sentence saying what to change so an offender passes, so the reader can act
//    without reconstructing the fix from the match;
//  - the HOME, a repository path plus the heading or bold lead-in under which the rule is
//    written, so the reader can read the reason before deciding to add an exemption.
//
//  A test declares its rules as `static let` values near the top of its suite and hands the
//  offenders to `failure(_:)` or `comment(_:)`. The offender lines are the test's own; this
//  type only frames them. `ScannerMessagePolicyTests` fails the build on a scanner that does
//  not report through one.

import Testing

/// The frame around a policy test's offenders: what the rule is, how to fix a line that
/// breaks it, and where the rule is written.
public struct PolicyRule: Sendable {
  /// One sentence: what must or must not happen.
  public let rule: String
  /// One sentence: what to change to make an offender pass.
  public let fix: String
  /// Where the rule is written: a repository path plus the heading or bold lead-in under
  /// which it appears, such as `CLAUDE.md, "Never construct Process"` or
  /// `docs/WRITING.md, "Code font is a claim"`.
  public let home: String

  public init(rule: String, fix: String, home: String) {
    self.rule = rule
    self.fix = fix
    self.home = home
  }

  /// The failure text: the rule, then `Fix: …`, then `Rule: …` naming the home, then the
  /// offenders one per line.
  public func failure(_ offenders: [String]) -> String {
    var lines = [rule, "Fix: \(fix)", "Rule: \(home)"]
    lines.append(contentsOf: offenders)
    return lines.joined(separator: "\n")
  }

  /// `failure(_:)` over offences, each printed as `path:line: text`.
  public func failure(_ offences: [Offence]) -> String {
    failure(offences.map(\.description))
  }

  /// `failure(_:)` as the comment an `#expect` takes.
  public func comment(_ offenders: [String]) -> Comment {
    Comment(rawValue: failure(offenders))
  }

  /// `comment(_:)` over offences, each printed as `path:line: text`.
  public func comment(_ offences: [Offence]) -> Comment {
    Comment(rawValue: failure(offences))
  }
}
