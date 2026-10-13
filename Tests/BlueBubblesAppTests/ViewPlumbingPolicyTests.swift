//  ViewPlumbingPolicyTests
//  The shapes a view used to build by hand, refused now that each has one door.
//
//  Each scan reads the tree through `SourceScanner`, ignores comments, and prints every
//  offender with its file and line, in the shape of `ServerStoppedNoticeTests`: a SwiftUI view
//  cannot be inspected from a test process without trapping, so the source is what is checked.

import BBTestSupport
import Foundation
import Testing

@Suite("View plumbing policy")
struct ViewPlumbingPolicyTests {

  // MARK: - Presence bindings

  /// `Binding.isPresent` is the one way to present over an optional. Seven hand-written copies
  /// existed, in two shapes, and a copy that forgets to clear what it presented leaves a
  /// dialog that reopens on the next render.
  @Test("A presentation over an optional goes through Binding.isPresent")
  func noHandBuiltPresence() throws {
    let offenders = try Self.scan(
      Self.app, matching: #"get:\s*\{[^}]*!=\s*nil\s*\}"#,
      except: ["Binding+Presence.swift"])
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a presence binding is written by hand; use `.isPresent($optional)` or "
          + "`.isPresent({ … }, dismiss: { … })`:\n" + offenders.report))
  }

  // MARK: - Settings

  /// `model.settings` (`SettingsModel`) is the one door from a view to a setting. A view
  /// holding the raw store did nothing when there was none: twenty-four
  /// `guard let store = model.settingsStore else { return }` across nine views, each a write
  /// that skipped itself and said nothing.
  @Test("A view reaches settings through model.settings, never the raw store")
  func noRawSettingsStoreInViews() throws {
    let offenders = try Self.scan(Self.views, matching: #"\bSettingsStore\b|\bsettingsStore\b"#)
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a view holds the raw settings store; go through `model.settings`:\n"
          + offenders.report))
  }

  /// A view never subscribes on its own. Five `for await … store.changes()` loops lived in
  /// views; the model follows the store and a view keys a `.task(id:)` on
  /// `model.settings.version(of:)` instead.
  @Test("A view never subscribes to a stream of changes itself")
  func noSubscriptionInViews() throws {
    let offenders = try Self.scan(Self.views, matching: #"\.changes\(\)"#)
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a view subscribes to changes itself; follow on the model and key a "
          + "`.task(id:)` on its version (`model.settings.version(of:)`):\n"
          + offenders.report))
  }

  /// A view being torn down cannot show what a write refused, so a write there is a refusal
  /// nobody sees: a rejected password sat in a field that no longer existed, saved as far as
  /// anyone could tell. Keep the edit (`model.settings.keepDraft`) and commit where the
  /// failure can be shown.
  ///
  /// Matched on what the closure CALLS: a commit or save of any name, or a settings write.
  /// A helper that writes under another name gets past this, which is why the helpers that
  /// exist are named for what they do (`keepUncommittedDraft`).
  @Test("Nothing commits or writes a setting in .onDisappear")
  func noWriteOnDisappear() throws {
    let write = try Regex(#"\b(commit|save)\w*\(|\.(set|write|reset|trySet|remove)\("#)
    var offenders: [String] = []
    var closures = 0
    try Self.forEachSource(in: Self.app) { file, lines in
      let source = lines.joined(separator: "\n")
      var searchFrom = source.startIndex
      while let opener = source[searchFrom...].range(of: ".onDisappear") {
        searchFrom = opener.upperBound
        let body = Self.braced(source, from: opener.upperBound)
        closures += 1
        guard body.contains(write) else { continue }
        let line = source[..<opener.lowerBound].filter { $0 == "\n" }.count + 1
        offenders.append(
          "\(file.path):\(line): .onDisappear "
            + body.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
      }
    }
    #expect(closures > 0, "found no .onDisappear at all; the scan is not reading the tree")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a view writes as it is torn down, where a refusal cannot be shown; keep "
          + "the edit instead (`model.settings.keepDraft`):\n" + offenders.joined(separator: "\n")))
  }

  // MARK: - Scanning

  /// The text between the first `{` at or after `start` and the brace that closes it.
  static func braced(_ source: String, from start: String.Index) -> Substring {
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

  static var app: String { "Sources/BlueBubblesApp" }
  static var views: String { "Sources/BlueBubblesApp/Views" }

  /// Every code line under `directory` matching `pattern`, outside the files whose paths end
  /// in one of `exempt`.
  ///
  /// With a FLOOR on what was read: a walk that finds no files passes, and the rule then
  /// stops being enforced while looking exactly like compliance.
  static func scan(
    _ directory: String, matching pattern: String, except exempt: Set<String> = [],
    minimumFiles: Int = 11
  ) throws -> [Offence] {
    let regex = try Regex(pattern)
    let files = try SourceScanner.swiftFiles(under: directory, minimum: minimumFiles)
      .filter { file in !exempt.contains(where: file.path.hasSuffix) }
    return SourceScanner.offences(in: files) { _, line in line.code.contains(regex) }
  }

  /// Calls `body` with each Swift file under `directory` and its lines with comments
  /// removed, so a sentence explaining a rule is not read as breaking it. Line numbers are
  /// preserved: `lines[n]` is line `n + 1`.
  static func forEachSource(
    in directory: String, _ body: (_ file: SourceFile, _ lines: [String]) throws -> Void
  ) throws {
    for file in try SourceScanner.swiftFiles(under: directory) {
      try body(file, file.lines.map(\.code))
    }
  }
}
