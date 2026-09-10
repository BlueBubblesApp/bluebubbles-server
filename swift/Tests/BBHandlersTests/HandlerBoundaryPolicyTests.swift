//  HandlerBoundaryPolicyTests
//  A handler parses, calls one interface, and serializes. It does not reach the helper.
//
//  The architecture's test for where logic belongs is "could the SwiftUI window call this
//  without going through HTTP?" A handler that takes the Private API client itself, or the
//  FaceTime coordinator, or the FindMy runtime, fails that test: the FaceTime dial handler
//  grew a pre-flight, a dial, a link, a ledger write and a hand-off before anything noticed,
//  and the app could reach none of it. `FaceTimeInterface` and `FindMyInterface` hold those
//  now, and this scan keeps them there, in the shape of `SettingKeyLiteralTests`.
//
//  THE ALLOWLIST IS DEBT, NOT PERMISSION. Three handler files still take the client directly
//  for a handful of one-line calls; each is named here so the list can only shrink. Moving
//  one behind an interface means deleting its line below.

import Foundation
import Testing

@Suite("Handlers stay on their side of the interface boundary")
struct HandlerBoundaryPolicyTests {

  /// Handlers that still reach the helper directly. Remove a file from here when its calls
  /// move behind an interface; never add one.
  private static let remainingDebt: Set<String> = [
    "MediaHandlers.swift",  // purged-attachment download, group photo, contact sharing
    "SystemHandlers.swift",  // account info, contact card, alias
    "StickerHandlers.swift",  // sticker save
  ]

  @Test("No handler takes the Private API client, the FaceTime coordinator or the FindMy runtime")
  func noDirectHelperReach() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BBHandlers")
    let pattern = try Regex(
      #"requirePrivateAPI\(|privateAPIClient\(\)|\.faceTime\(\)|\.findMy\.|\.findMy\b(?!Interface)"#
    )

    var offenders: [String] = []
    var scanned = 0
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      scanned += 1
      if Self.remainingDebt.contains(relative) { continue }
      // The capability protocols themselves are declared beside the handlers.
      if relative == "HandlerCapabilities.swift" { continue }
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        if code.contains(pattern) {
          offenders.append("Sources/BBHandlers/\(relative):\(index + 1): \(code)")
        }
      }
    }
    #expect(scanned > 10, "the handler directory looks empty, which would make this vacuous")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue:
          "a handler reaches the helper directly; put the operation on an interface and call that:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  @Test("Every file on the debt list still exists, so a moved file is struck off")
  func debtListIsCurrent() {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    for file in Self.remainingDebt {
      let path = root.appending(path: "Sources/BBHandlers/\(file)").path
      #expect(FileManager.default.fileExists(atPath: path), "\(file) is on the debt list but gone")
    }
  }
}
