//  SharedComponentPolicyTests
//  A shape that has a component is drawn by the component.
//
//  Each shape here was drawn by hand at several sites, and the copies had drifted before
//  anyone extracted them: a service's status line (five sites, two sizes, one re-declaring
//  the line as a tuple), a navigable row's chevron (three rows, three spacings), a file drop
//  target (two zones, one batching its files and one not), a relative age (five sites, two
//  presentations, each counting seconds), a pasteboard write (four sites), a section's empty
//  line (nine sites, three fonts) and a card's headline (nine cards, three spacings). Each
//  has one home, and the token that gave the hand-drawn copies away is refused everywhere
//  else.
//
//  A source scan, in the shape of `ServerStoppedNoticeTests`, because a SwiftUI view cannot
//  be inspected from a test without trapping. Comments are skipped, so a comment naming
//  the token is not an offence.

import BBTestSupport
import Foundation
import Testing

@Suite("Shared components")
struct SharedComponentPolicyTests {

  /// A token, the one file allowed to spell it, and what to use instead.
  private struct Rule {
    let token: String
    /// Relative to `Sources/BlueBubblesApp`.
    let home: String
    let remedy: String
    /// Where the token is refused, relative to `Sources/BlueBubblesApp`. Most rules are about
    /// views; one whose door is a helper rather than a view is refused across the module,
    /// because the summaries that format for a view live beside `Views/`, not in it.
    var scope = "Views/"
  }

  private static let rules = [
    // A status line coloured by hand reads `isProblem` to pick its colour.
    // `ServiceStatusSummary.Line.tone` is the colour, and lives beside the rule that decides
    // it, outside `Views/`.
    Rule(
      token: "isProblem",
      home: "Views/Components/ServiceStatusLine.swift",
      remedy: "draw a `ServiceStatusSummary.Line` with `ServiceStatusLine`"),
    // A navigable row's chevron. A `Label("Next", systemImage: "chevron.right")` on a pager
    // is a button, spelled differently, and is not caught.
    Rule(
      token: #"Image(systemName: "chevron.right")"#,
      home: "Views/Components/ManifestRow.swift",
      remedy: "a row that leads somewhere is a `ManifestRow` with `showsChevron: true`"),
    Rule(
      token: ".onDrop(",
      home: "Views/Components/DropZone.swift",
      remedy: "use `DropZone`, or `acceptsFileDrop` for a whole page"),
    // A relative age that counts seconds changes on every render for its first minute, and
    // a changed string inside glass is a glass re-sample. The three spellings of one.
    Rule(
      token: ".relative(presentation",
      home: "HomeDashboard.swift",
      remedy: "a relative age goes through `HomeDashboard.relative(_:to:)`", scope: ""),
    Rule(
      token: "RelativeDateTimeFormatter",
      home: "HomeDashboard.swift",
      remedy: "a relative age goes through `HomeDashboard.relative(_:to:)`", scope: ""),
    Rule(
      token: "style: .relative",
      home: "HomeDashboard.swift",
      remedy: "a relative age goes through `HomeDashboard.relative(_:to:)`; a `.relative` "
        + "text style is a timer that redraws every second", scope: ""),
    Rule(
      token: "NSPasteboard",
      home: "Pasteboard.swift",
      remedy: "copy through `Pasteboard.copy(_:)`", scope: ""),
    // A quit that skips the delegate's shutdown (the menu bar stopped the server itself and
    // then terminated, so the deadline never applied), or one made from a sheet, which
    // never reaches the delegate at all.
    // The address a person types into a client. Six screens derived it themselves and
    // disagreed about following a republish, the localhost fallback and the copy button.
    Rule(
      token: "Settings.serverAddress",
      home: "AddressObservation.swift",
      remedy: "show the client address with `ServerAddressRow`, or read `model.clientAddress`"),
    Rule(
      token: ".terminate(",
      home: "AppTermination.swift",
      remedy: "quit through `AppTermination.quit()`, or `quitFromSheet` from a sheet",
      scope: ""),
  ]

  @Test("Status lines, rows, drop targets, ages, copies, addresses and quits use their doors")
  func shapesUseTheirComponents() throws {
    let app = ViewPlumbingPolicyTests.app + "/"
    var offenders: [String] = []
    var homesFound: Set<String> = []
    // FLOORS on what was scanned: a walk that finds nothing passes, and a home that has
    // moved would exempt nothing while every rule still looked enforced.
    for file in try SourceScanner.swiftFiles(under: ViewPlumbingPolicyTests.app, minimum: 11) {
      let relative = String(file.path.dropFirst(app.count))
      for rule in Self.rules {
        if relative == rule.home {
          homesFound.insert(rule.home)
          continue
        }
        // Per rule: `ServiceStatusSummary` names `isProblem` outside `Views/`, and it is
        // the rule rather than a breach of it.
        guard relative.hasPrefix(rule.scope) else { continue }
        for line in file.codeLines where line.code.contains(rule.token) {
          offenders.append(
            "\(file.path):\(line.number): \(rule.remedy)\n    "
              + line.text.trimmingCharacters(in: .whitespaces))
        }
      }
    }

    #expect(
      homesFound == Set(Self.rules.map(\.home)),
      "a component's file has moved; update the rule that exempts it")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a shared shape is drawn by hand; use its component:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  /// A generated password is generated by `SecretField`, which shows what it made. Setup's
  /// Generate put one into a plain `SecureField`, and the person finished setup with a
  /// password they could not read and so could not give to a single client.
  @Test("A generated secret is generated by the field that can show it")
  func generatedSecretsAreShown() throws {
    let files = try SourceScanner.swiftFiles(
      under: ViewPlumbingPolicyTests.app + "/Views", minimum: 11)
    let offenders = SourceScanner.offences(in: files) { _, line in
      line.code.contains("PasswordPolicy.generate(")
        && !line.code.contains("generator:") && !line.code.contains("make:")
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a password is generated outside `SecretField`'s `generator:`, so nothing "
          + "shows it:\n" + offenders.report))
  }

  /// A section's empty line is `SectionEmptyText`. Matched on the words a hand-drawn one
  /// opens with, which every one of the nine did; a sentence of that kind phrased otherwise
  /// gets past this, which is why the component's header names the shape as well.
  @Test("A section's empty line is SectionEmptyText")
  func emptyLinesUseTheirComponent() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views, matching: #"(^|[^A-Za-z])Text\("(No|None|Nothing)\b"#,
      except: ["Components/SectionEmptyText.swift"])
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a section's empty line is drawn by hand; use `SectionEmptyText`:\n"
          + offenders.report))
  }

  /// A glass card that opens with a literal title is `TitledCard`. The first `Text` within
  /// four lines of `GlassCard {` is the candidate, with its font on the same line or the
  /// next; it is a title when it is a literal (or a choice between two) set in a heading
  /// face. Matching `.headline` alone let three cards through at `.subheadline`,
  /// `.subheadline.weight(.semibold)` and `.callout.weight(.semibold)`: the very drift the
  /// component exists to stop. A card titled by a value (a device's name, a startup stage) or
  /// by a `Label` is a different shape and is not matched.
  @Test("A card that opens with a title is TitledCard")
  func titledCardsUseTheirComponent() throws {
    let literal = try Regex(#"Text\((?:"[^"]*"|[^()]*\?\s*"[^"]*"\s*:\s*"[^"]*")\)"#)
    let heading = try Regex(
      #"\.font\(\.(headline|subheadline|title\d?|callout\.weight\(\.semibold\)|body\.weight\(\.semibold\))[^)]*\)|\.bold\(\)|\.fontWeight\(\.semibold\)"#
    )
    var offenders: [String] = []
    var cards = 0
    try ViewPlumbingPolicyTests.forEachSource(in: ViewPlumbingPolicyTests.views) {
      file, lines in
      guard !file.path.hasSuffix("Components/TitledCard.swift") else { return }
      for (index, line) in lines.enumerated() where line.contains("GlassCard") {
        cards += 1
        let window = Array(lines[(index + 1)..<min(index + 5, lines.count)])
        guard let first = window.firstIndex(where: { $0.contains(literal) }) else { continue }
        let styled = window[first] + (first + 1 < window.count ? window[first + 1] : "")
        if styled.contains(heading) {
          offenders.append(
            "\(file.path):\(index + 1): "
              + line.trimmingCharacters(in: .whitespaces))
        }
      }
    }
    #expect(cards > 5, "found only \(cards) glass cards; the scan is not reading the tree")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a card draws its own headline; use `TitledCard`:\n"
          + offenders.joined(separator: "\n")))
  }

  /// A state is coloured through `StatusTone`, never with a colour of its own. Four
  /// vocabularies and five private colour maps had drifted: a starting server was a warning
  /// in one place and unknown in another. A chart's series colour is not a state, and is
  /// recognised by the gradient or the scale it is set through.
  @Test("A state's colour is a StatusTone's")
  func statusColoursAreTones() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views,
      matching: #"(^|[^A-Za-z0-9_])(Color)?\.(red|orange|green|yellow)\b(?!\.gradient)"#
    ).filter { !$0.text.contains("chartForegroundStyleScale") }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a state is coloured by hand; map it to a `StatusTone` and use `tint`:\n"
          + offenders.report))
  }

  /// Rows with a divider between each pair are `DividedForEach`. Twelve lists drew it by
  /// hand in two spellings, one of them keying the `ForEach` through an enumerated tuple.
  @Test("A divided list is DividedForEach")
  func dividedListsUseTheirComponent() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views,
      matching: #"if [^{]*(index > 0|!= [^{]*\.first\?)[^{]*\{ *(Settings)?Divider\("#,
      except: ["Components/DividedForEach.swift"])
    #expect(
      offenders.isEmpty,
      Comment(rawValue: "a list divides its own rows; use `DividedForEach`:\n" + offenders.report))
  }

  /// A tick box over a set is `Binding(contains:in:)`. Four views wrote the get-contains,
  /// set-insert-or-remove closure by hand. A switch whose write goes to the server (a
  /// contact's Served column reads `!disabledIDs.contains`) is not a set the view owns, and
  /// is not matched.
  @Test("A tick box over a set is Binding(contains:in:)")
  func membershipBindingsUseTheirDoor() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views, matching: #"get: \{ [A-Za-z_.]+\.contains\("#)
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a membership binding is written by hand; use `Binding(contains:in:)`:\n"
          + offenders.report))
  }

  /// A failure said in a line is `ErrorLine`. Nine spellings had grown up, and two of them
  /// were copies of the view this one replaced.
  @Test("A failure line is ErrorLine")
  func failureLinesUseTheirComponent() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views,
      matching: #"accessibilityLabel\("Error: "#,
      except: ["Components/ErrorLine.swift"])
    #expect(
      offenders.isEmpty,
      Comment(rawValue: "a failure line is drawn by hand; use `ErrorLine`:\n" + offenders.report))
  }
}
