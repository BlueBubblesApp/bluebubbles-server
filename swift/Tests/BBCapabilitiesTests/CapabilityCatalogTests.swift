//  CapabilityCatalogTests
//  The two things that keep `PrivateAPICapability` from going stale on its own.
//
//  A catalog that drives a screen is only worth having if it cannot quietly become wrong, and
//  there are exactly two ways it could: the version could stop matching what the header dumps
//  say, or the copy could stop being readable by the person it is written for. One test each.

import Foundation
import Testing

@testable import BBCapabilities

@Suite("Capability catalog")
struct CapabilityCatalogTests {

  /// `swift/docs/headers`, reached by path — the dumps live outside every target.
  private static var headersDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // BBCapabilitiesTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("docs/headers")
  }

  /// Every dumped release, as (major version, directory).
  private static var releases: [(major: Int, url: URL)] {
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: headersDirectory, includingPropertiesForKeys: nil)) ?? []
    return
      contents
      .filter { $0.lastPathComponent.hasPrefix("macos-") }
      .compactMap { url in
        let name = url.lastPathComponent.replacingOccurrences(of: "macos-", with: "")
        guard let major = Int(name.split(separator: ".").first.map(String.init) ?? "") else {
          return nil
        }
        return (major, url)
      }
      .sorted { $0.major < $1.major }
  }

  /// Whether a class is present in a release's dump.
  ///
  /// A header that exists and says `NOT PRESENT` is a measured absence; a header that does
  /// not exist at all is a gap in `hosts.conf` and is reported as such rather than counted
  /// as absence — the distinction `docs/headers/README.md` exists to protect.
  private static func classPresent(_ name: String, in release: URL) throws -> Bool? {
    let file = release.appendingPathComponent("\(name).h")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return !text.contains("is NOT PRESENT")
  }

  /// Whether a class declares a selector, reconstructed from the declaration.
  ///
  /// Not a substring search for the selector: a declaration interleaves the argument types
  /// between the keywords, so `markAsSpam:isJunkReportedToCarrier:` never appears literally
  /// in `- (unsigned long long)markAsSpam:(unsigned long long)arg0 isJunkReportedToCarrier:`.
  /// Grepping for it reports every multi-argument selector as missing, which is exactly the
  /// mistake `docs/SONOMA_COMPATIBILITY.md` §7 records.
  private static func selectorPresent(
    _ selector: String, onClass className: String, in release: URL
  ) throws -> Bool? {
    let file = release.appendingPathComponent("\(className).h")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    if text.contains("is NOT PRESENT") { return false }
    for declaration in text.split(separator: ";") {
      let line = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix("-") || line.hasPrefix("+") else { continue }
      guard let body = line.range(of: ")").map({ String(line[$0.upperBound...]) }) else {
        continue
      }
      let keywords = body.split(separator: ":", omittingEmptySubsequences: false)
        .dropLast()
        .compactMap { part -> String? in
          let token = part.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .last
          return token.map(String.init)
        }
      let reconstructed =
        keywords.isEmpty
        ? body.trimmingCharacters(in: .whitespaces)
        : keywords.map { $0 + ":" }.joined()
      if reconstructed == selector { return true }
    }
    return false
  }

  @Test("Every declared minimum is the oldest release whose dump has the evidence")
  func minimumsMatchTheHeaderDumps() throws {
    let releases = Self.releases
    #expect(releases.count >= 2, "need at least two dumps to check a minimum against")

    for capability in PrivateAPICapability.all {
      guard case let evidence = capability.evidence else { continue }
      if case .notVisibleInHeaders(let reason) = evidence {
        #expect(
          !reason.isEmpty,
          "\(capability.id) opts out of the dump check and must say why")
        continue
      }

      var oldestPresent: Int?
      for release in releases {
        let present: Bool? =
          switch evidence {
          case .classExists(let name):
            try Self.classPresent(name, in: release.url)
          case .selectorExists(let selector, let className):
            try Self.selectorPresent(selector, onClass: className, in: release.url)
          case .anySelectorExists(let selectors, let className):
            try selectors.reduce(nil as Bool?) { answer, selector in
              // nil (class not dumped) only survives if EVERY rung is unanswerable.
              let one = try Self.selectorPresent(selector, onClass: className, in: release.url)
              guard let one else { return answer }
              return (answer ?? false) || one
            }
          case .notVisibleInHeaders:
            nil
          }
        // A class nobody dumped cannot confirm or deny anything; skip that release rather
        // than reading its silence as an answer.
        guard let present else { continue }
        if present, oldestPresent == nil { oldestPresent = release.major }
        if !present {
          #expect(
            release.major < capability.minimumMacOS,
            """
            \(capability.id) is declared as macOS \(capability.minimumMacOS)+, but its \
            evidence is ABSENT on macOS \(release.major), which is at or above that minimum.
            """)
        }
      }

      if let oldestPresent {
        #expect(
          oldestPresent == capability.minimumMacOS,
          """
          \(capability.id) is declared as macOS \(capability.minimumMacOS)+, but the dumps \
          show its evidence first appearing on macOS \(oldestPresent). Update the \
          declaration, or the evidence if it names the wrong thing.
          """)
      }
    }
  }

  /// The catalog is read by people choosing whether to upgrade macOS, not by people reading
  /// this repository. A class or selector name on that screen is noise at best and
  /// intimidating at worst, so it is a test failure rather than a review comment.
  ///
  /// `evidence` is exempt by construction: it is not user-facing and is never rendered.
  @Test("No user-facing text names an Apple class, selector or framework")
  func copyIsPlainLanguage() {
    // Apple's private-class prefixes, plus the shapes an API name takes in this codebase.
    let prefixes = ["IM", "CK", "TU", "STK", "FMF", "FMD", "MS", "IDS", "NS"]
    for capability in PrivateAPICapability.all {
      for (field, text) in [("title", capability.title), ("summary", capability.summary)] {
        let where_ = "\(capability.id).\(field)"
        #expect(!text.contains(":"), "\(where_) looks like it names a selector: \(text)")
        #expect(!text.contains("()"), "\(where_) names a function: \(text)")
        #expect(
          !text.contains(".framework"), "\(where_) names a framework: \(text)")
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
          let token = String(word)
          // An API name here is a capitalised prefix followed by more capitals —
          // `IMChat`, `CKComposition`. Ordinary sentence-initial words like "Muting" are
          // not, because the character after the prefix is lowercase.
          for prefix in prefixes where token.hasPrefix(prefix) && token.count > prefix.count {
            let next = token[token.index(token.startIndex, offsetBy: prefix.count)]
            #expect(
              !next.isUppercase,
              "\(where_) names what looks like an Apple type (\(token)): \(text)")
          }
          #expect(
            !token.contains("_"), "\(where_) contains an identifier (\(token)): \(text)")
        }
      }
      #expect(!capability.title.hasSuffix("."), "\(capability.id).title is a title, not a sentence")
      #expect(capability.summary.hasSuffix("."), "\(capability.id).summary should be a sentence")
    }
  }

  @Test("Identifiers are unique and wire-safe")
  func identifiersAreStable() {
    let ids = PrivateAPICapability.all.map(\.id)
    #expect(Set(ids).count == ids.count, "duplicate capability id")
    for id in ids {
      #expect(
        id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" },
        "\(id) should be lowercase kebab-case; it is a stable client-visible key")
    }
  }

  @Test("Upgrade paths group by release, newest first to match the upward arrows")
  func upgradePathsAreOrdered() {
    let paths = PrivateAPICapability.all.upgradePaths(from: 14)
    #expect(paths.map(\.macOS) == [26, 15])
    #expect(paths.allSatisfy { !$0.capabilities.isEmpty })
    // Nothing is offered as an upgrade on the newest release we know about.
    #expect(PrivateAPICapability.all.upgradePaths(from: 26).isEmpty)
    #expect(PrivateAPICapability.all.available(on: 26).count == PrivateAPICapability.all.count)
  }
}

@Suite("Feature listing")
struct FeatureListingTests {

  @Test("Connected on the newest release lists everything and offers no upgrade")
  func connectedOnNewest() {
    let entries = PrivateAPICapability.listing(macOSMajor: 26, privateAPIConnected: true)
    #expect(entries.featureCount == PrivateAPICapability.all.count)
    #expect(entries.allSatisfy { entry in
      if case .feature(_, let availability) = entry { return availability == .available }
      return true
    })
    #expect(!entries.contains { if case .heading(let t, _) = $0 { return t.contains("Upgrade") } else { return false } })
  }

  @Test("Connected on an older release separates what an upgrade would add")
  func connectedOnOlder() {
    let entries = PrivateAPICapability.listing(macOSMajor: 14, privateAPIConnected: true)
    let upgradeHeadings = entries.compactMap { entry -> String? in
      if case .heading(let text, true) = entry, text.hasPrefix("Upgrade") { return text }
      return nil
    }
    // Newest first, matching the upward arrows the view draws.
    #expect(upgradeHeadings.count == 2)
    #expect(upgradeHeadings.first?.contains("26") == true)
    #expect(upgradeHeadings.last?.contains("15") == true)
    #expect(entries.featureCount == PrivateAPICapability.all.count)
  }

  /// The bug that started this: a macOS 14 user with the Private API off saw an empty card,
  /// because the catalog only held version-gated features and none of them are on 14.
  @Test("Not connected always lists something to gain, on every release")
  func notConnectedIsNeverEmpty() {
    for macOS in [14, 15, 26] {
      let entries = PrivateAPICapability.listing(macOSMajor: macOS, privateAPIConnected: false)
      #expect(entries.featureCount > 0, "macOS \(macOS) with no Private API showed nothing")
      let reachable = entries.filter {
        if case .feature(_, let availability) = $0 { return availability == .needsPrivateAPI }
        return false
      }
      #expect(
        reachable.count == PrivateAPICapability.all.available(on: macOS).count,
        "everything this macOS supports should be offered as something to unlock")
    }
  }

  @Test("Collapsing counts features, not headings, and never ends on a heading")
  func collapsing() {
    let entries = PrivateAPICapability.listing(macOSMajor: 14, privateAPIConnected: false)
    #expect(entries.featureCount > 6)

    let collapsed = entries.collapsed(toFeatures: 6)
    #expect(collapsed.featureCount == 6, "headings must not consume the budget")
    #expect(
      collapsed.last?.isFeature == true,
      "a collapsed list must not end on a heading, separator or note")
    #expect(collapsed.count < entries.count)
    // The prefix is a prefix: order is preserved and nothing is reordered on collapse.
    #expect(Array(entries.prefix(collapsed.count)).map(\.id) == collapsed.map(\.id))
  }

  @Test("A listing that already fits is returned whole")
  func collapsingShortList() {
    let entries = PrivateAPICapability.listing(macOSMajor: 26, privateAPIConnected: true)
    let limit = entries.featureCount
    #expect(entries.collapsed(toFeatures: limit).count == entries.count)
    #expect(entries.collapsed(toFeatures: limit + 5).count == entries.count)
  }

  @Test("The upgrade block is separated, and its order is explained once")
  func upgradeBlockIsMarkedOff() {
    let entries = PrivateAPICapability.listing(macOSMajor: 14, privateAPIConnected: true)

    // A rule before each upgrade group, and never as the first thing on the card.
    #expect(entries.first != .separator)
    let separators = entries.filter { $0 == .separator }.count
    #expect(separators == PrivateAPICapability.all.upgradePaths(from: 14).count)

    // The ordering note is said once, and it sits above the first upgrade heading.
    let notes = entries.compactMap { entry -> String? in
      if case .note(let text) = entry { return text }
      return nil
    }
    #expect(notes.count == 1)
    let noteIndex = entries.firstIndex { if case .note = $0 { return true } else { return false } }
    let firstUpgradeHeading = entries.firstIndex {
      if case .heading(let text, _) = $0 { return text.hasPrefix("Upgrade") }
      return false
    }
    #expect(noteIndex != nil && firstUpgradeHeading != nil)
    #expect(noteIndex! < firstUpgradeHeading!)
  }

  @Test("With one upgrade there is no order to explain, so nothing is said")
  func noOrderingNoteForASingleUpgrade() {
    let entries = PrivateAPICapability.listing(macOSMajor: 15, privateAPIConnected: true)
    #expect(PrivateAPICapability.all.upgradePaths(from: 15).count == 1)
    #expect(!entries.contains { if case .note = $0 { return true } else { return false } })
    #expect(entries.contains(.separator), "the block is still marked off")
  }

  @Test("The not-connected card separates the part an upgrade also gates")
  func notConnectedSeparatesUpgradeHalf() {
    let entries = PrivateAPICapability.listing(macOSMajor: 14, privateAPIConnected: false)
    #expect(entries.contains(.separator))
    #expect(entries.first != .separator)
    // Only one rule: there is one block below the line, not one per release.
    #expect(entries.filter { $0 == .separator }.count == 1)
  }

  @Test("Every heading is plain language too")
  func headingsAreReadable() {
    for macOS in [14, 15, 26] {
      for connected in [true, false] {
        let entries = PrivateAPICapability.listing(
          macOSMajor: macOS, privateAPIConnected: connected)
        for entry in entries {
          guard case .heading(let text, _) = entry else { continue }
          // `(` alone is not a smell — "macOS Tahoe (26)" is exactly how a release should
          // be named. `()` is, because that is a function.
          #expect(!text.contains(":"), "heading looks like a selector: \(text)")
          #expect(!text.contains("()"), "heading names a function: \(text)")
          #expect(!text.contains("_"), "heading contains an identifier: \(text)")
        }
      }
    }
  }
}
