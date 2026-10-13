//  OperatorAttributionPolicyTests
//  Every change the app makes to the server is recorded as the person's.
//
//  The audit log records work nothing attributed as `unattributed`, deliberately: blaming the
//  person at the Mac for work nobody traced is the worse error. So the app has to say when
//  the person is acting, and it does so with `asOperator` around the call. A screen that
//  forgets does not fail; it writes an audit row that says nobody did it. This scan is what
//  makes forgetting fail the build.
//
//  It finds each call that changes audited state (a settings write, an access-control change,
//  a webhook or schedule change, an import, a licence exchange) and walks back through the
//  braces that enclose it. One of those scopes has to be opened by `asOperator`, by an
//  explicit `AuditContext` scope (the app's own bookkeeping is `.system`), or by one of the
//  LANES below, each of which is itself checked to run its body as the operator. A call
//  through one of the DOORS below needs none at the call site: the door opens one inside
//  every write it offers, and that is checked too.

import BBTestSupport
import Foundation
import Testing

@Suite("Operator attribution policy")
struct OperatorAttributionPolicyTests {

  /// Calls that change state the audit log records, by the names the app's code gives the
  /// objects it calls them on. Receiver names rather than method names alone, because
  /// `set(` and `write(` are everywhere: a JSON builder, `UserDefaults`, a settings batch.
  static let auditedCalls = [
    #"\b(store|settings)\.(set|trySet|write|remove)\("#,
    #"\bsetting\.write\("#,
    #"resetToDefaults\("#,
    #"(accessControl|\$0)\.(unblock|allow|disallow|clearAllBlocks|blockPermanently)\("#,
    #"\b(create|update|delete)Webhook\("#,
    #"\bscheduling\.(create|update|delete|clearFinished)\("#,
    #"\bimporter\.apply\("#,
    #"\bsubscription\.(refresh|remove)\("#,
  ]

  /// What may open the enclosing scope.
  static let openers = ["asOperator", "AuditContext.acting(", "AuditContext.with("]

  /// Helpers that take a closure and run it as the operator, so a call inside one is
  /// attributed. Each names the file that defines it; `lanesRunAsOperator` reads that
  /// definition and fails if it stops doing so.
  static let lanes: [(opener: String, definedIn: String, definition: String)] = [
    ("screen.perform", "ScreenModel.swift", "func perform("),
    ("mutate", "Views/SecurityAdministration.swift", "private func mutate("),
  ]

  /// Objects whose every write runs as the operator, so a call through one is attributed
  /// wherever it is made. `owner` and `member` name the receiver as the app spells it
  /// (`model.settings.set(`); `doorsRunAsOperator` reads each writer in `definedIn` and fails
  /// if one stops opening `asOperator`. `SettingsModel` is the one door to settings, and a
  /// view that had to remember `asOperator` around each of its writes is what it replaced.
  static let doors: [(owner: String, member: String, definedIn: String, writers: [String])] = [
    (
      "model.", "settings", "Models/SettingsModel.swift",
      [
        "func set<Value", "func write(_ setting:", "func set(_ value: String",
        "func write(_ batch:", "func reset(",
      ]
    )
  ]

  /// The app's sources, where every path below is written relative to.
  private static let app = "Sources/BlueBubblesApp/"

  @Test("Every audited change the app makes runs as the operator")
  func auditedChangesRunAsOperator() throws {
    // SIMPLE word boundaries. The default is Unicode's (UAX #29), under which a `.` between
    // letters does not break a word, so `\b` never matches inside `model.serverAdmin.x(`
    // and every call reached through a property would be silently skipped.
    let patterns = try Self.auditedCalls.map { try Regex($0).wordBoundaryKind(.simple) }
    let accepted = Self.openers + Self.lanes.map(\.opener)

    var offences: [Offence] = []
    var auditedCallsFound = 0
    // FLOORS on what was scanned, so a walk that finds nothing cannot look like compliance.
    for file in try SourceScanner.swiftFiles(under: "Sources/BlueBubblesApp", minimum: 11) {
      let sourceLines = file.lines
      let lines = sourceLines.map(\.code)
      for (index, line) in lines.enumerated() {
        for pattern in patterns {
          for match in line.matches(of: pattern) {
            auditedCallsFound += 1
            let receiver = line[..<match.range.lowerBound]
            let throughDoor = Self.doors.contains { door in
              receiver.hasSuffix(door.owner) && line[match.range].hasPrefix(door.member + ".")
            }
            if throughDoor { continue }
            guard !Self.isEnclosed(lines, line: index, before: match.range.lowerBound, by: accepted)
            else { continue }
            offences.append(Offence(file, sourceLines[index]))
          }
        }
      }
    }

    #expect(
      auditedCallsFound > 15,
      "found only \(auditedCallsFound) audited calls; the patterns no longer match the app")
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "these change audited state outside `asOperator`, so the audit log records "
          + "them as unattributed:\n" + offences.report))
  }

  @Test("Each lane the scan accepts runs its body as the operator")
  func lanesRunAsOperator() throws {
    for lane in Self.lanes {
      let source = try SourceScanner.file(Self.app + lane.definedIn).code
      let start = try #require(
        source.range(of: lane.definition), "\(lane.definedIn) no longer defines \(lane.opener)")
      // The definition's body: from its opening brace to the brace that closes it.
      let body = Self.braced(source, from: start.upperBound)
      #expect(
        body.contains("asOperator"),
        "\(lane.opener) in \(lane.definedIn) no longer runs its body as the operator")
    }
  }

  @Test("Each door the scan accepts runs every write it offers as the operator")
  func doorsRunAsOperator() throws {
    for door in Self.doors {
      let source = try SourceScanner.file(Self.app + door.definedIn).code
      for writer in door.writers {
        let start = try #require(
          source.range(of: writer), "\(door.definedIn) no longer defines `\(writer)`")
        let body = Self.braced(source, from: start.upperBound)
        #expect(
          body.contains("asOperator"),
          Comment(
            rawValue: "`\(writer)` in \(door.definedIn) no longer runs its write as the "
              + "operator, so every call through `\(door.owner)\(door.member)` is recorded "
              + "as unattributed"))
      }
    }
  }

  // MARK: - Reading source

  /// Whether the call at `column` on `line` sits inside a scope opened on a line containing
  /// one of `openers`, walking outwards brace by brace.
  private static func isEnclosed(
    _ lines: [String], line: Int, before column: String.Index, by openers: [String]
  ) -> Bool {
    var unclosed = 0
    var index = line
    var text = Substring(lines[line][..<column])
    while true {
      var position = text.endIndex
      while position > text.startIndex {
        position = text.index(before: position)
        switch text[position] {
        case "}":
          unclosed += 1
        case "{" where unclosed > 0:
          unclosed -= 1
        case "{":
          // This brace opens a scope around the call. Is it one that names the operator?
          let opener = text[..<position]
          if openers.contains(where: opener.contains) { return true }
        default:
          continue
        }
      }
      index -= 1
      guard index >= 0 else { return false }
      text = Substring(lines[index])
    }
  }

  /// The text between the first `{` at or after `start` and its matching `}`.
  private static func braced(_ source: String, from start: String.Index) -> Substring {
    guard let open = source[start...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var position = open
    while position < source.endIndex {
      switch source[position] {
      case "{": depth += 1
      case "}":
        depth -= 1
        if depth == 0 { return source[open...position] }
      default: break
      }
      position = source.index(after: position)
    }
    return source[open...]
  }
}
