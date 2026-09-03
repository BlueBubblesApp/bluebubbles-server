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

  @Test("Upgrade paths group by release, oldest upgrade first")
  func upgradePathsAreOrdered() {
    let paths = PrivateAPICapability.all.upgradePaths(from: 14)
    #expect(paths.map(\.macOS) == [15, 26])
    #expect(paths.allSatisfy { !$0.capabilities.isEmpty })
    // Nothing is offered as an upgrade on the newest release we know about.
    #expect(PrivateAPICapability.all.upgradePaths(from: 26).isEmpty)
    #expect(PrivateAPICapability.all.available(on: 26).count == PrivateAPICapability.all.count)
  }
}
