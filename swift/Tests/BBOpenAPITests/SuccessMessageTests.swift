//  SuccessMessageTests
//  The envelope's `message` strings are the reference's, character for character.
//
//  `SuccessMessages.byHandler` is data transcribed out of another codebase: about fifty
//  strings spread across seventeen router files, none of them remarkable on its own. A typo
//  in one is invisible everywhere it matters. The shape is right, the type is right, the key
//  is right, and the parity diff compares keys and types, so `"Ping recieved!"` would pass
//  every other check this project has and reach every client that has ever talked to a
//  BlueBubbles server.
//
//  This suite is the independent transcription that three separate comments claimed existed.
//  It did not: `SuccessMessages.swift`, `SuccessMessageKeyTests.swift` and `docs/TESTING.md`
//  each said a `SuccessMessageTests` checked the strings, and no such file was ever written.
//  The key test's own scope was narrowed on the strength of that claim, so between them the
//  strings had no check at all.
//
//  **The reference is read, not remembered.** The strings are scanned out of
//  `packages/server/src/server/api/http/api/v1/routers/*.ts` at test time, which is the point
//  of calling it independent: a transcription checked against a second transcription proves
//  only that the same person typed the same thing twice. That tree is committed in this
//  repository as the frozen reference, so this needs nothing a checkout does not have.
//
//  What it asserts, and what it does not
//  ------------------------------------
//  FORWARD: every string this server sends is one the reference sends. That is the direction
//  that matters, because a string we invented is a divergence a client sees.
//
//  It does NOT assert the reverse, that every reference string appears here. A missing entry
//  degrades the route to `"Success"`, which is a real bug, but it is one `SuccessMessageKeyTests`
//  and the fixture replay are positioned to catch, and the reverse direction cannot be
//  asserted cleanly: the reference also carries conditional strings its handlers choose
//  between at runtime (`themeRouter.get` answers "No saved themes!" or
//  "Successfully fetched theme(s)!" depending on the row count), and those deliberately live
//  on the handler here rather than in the table.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBOpenAPI
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Success message strings")
struct SuccessMessageTests {

  /// `packages/server/…/routers`, located from this file rather than the working directory.
  private static var routerDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // BBOpenAPITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .deletingLastPathComponent()  // repository root
      .appending(path: "packages/server/src/server/api/http/api/v1/routers")
  }

  /// Every string the reference passes to `new Success(…)`.
  ///
  /// Scanned rather than parsed. A TypeScript parser would be the precise tool and is far
  /// more than this needs: the call is always `new Success(ctx, { … message: "…" … })`, and
  /// taking the window between the call and its closing brace catches both the single-line
  /// and wrapped forms the formatter produces.
  private static func referenceStrings() throws -> Set<String> {
    let files = try FileManager.default.contentsOfDirectory(
      at: routerDirectory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "ts" }

    // BOTH quote styles. TypeScript takes either and the reference uses both: five of its
    // success strings are single-quoted, including the two on the contact-sharing routes.
    // A double-quote-only scan made those five invisible, so transcribing one of them
    // correctly was reported as a string "no BlueBubbles client has ever received".
    let message = try Regex(#"message:\s*(?:"([^"]*)"|'([^']*)')"#)
    var found: Set<String> = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      var index = source.startIndex
      while let call = source.range(of: "new Success(", range: index..<source.endIndex) {
        // The object literal ends at the first `})` after the call; a message never
        // contains one, and neither does anything between it and the call.
        let tail = source[call.upperBound...]
        let end = tail.range(of: "})")?.lowerBound ?? tail.endIndex
        for match in tail[tail.startIndex..<end].matches(of: message) {
          // Whichever alternative matched; the other capture is nil.
          if let value = match.output[1].substring ?? match.output[2].substring {
            found.insert(String(value))
          }
        }
        index = call.upperBound
      }
    }
    return found
  }

  @Test("The reference tree is present and was actually read")
  func referenceIsReadable() throws {
    #expect(
      FileManager.default.fileExists(atPath: Self.routerDirectory.path),
      """
      the reference routers are not at \(Self.routerDirectory.path). This suite checks our \
      strings against theirs; without that tree it checks nothing, and a silent skip here \
      is the failure mode it was written to end.
      """)
    let strings = try Self.referenceStrings()
    // Measured: the seventeen routers carry well over fifty distinct success strings. A
    // floor rather than an exact count, so adding a route to the reference does not fail
    // this, while a scan that stopped matching does.
    #expect(
      strings.count >= 40,
      "the scan found only \(strings.count) success strings in the reference; it has stopped matching"
    )
  }

  @Test("Every string this server sends is one the reference sends")
  func tableMatchesTheReference() throws {
    let reference = try Self.referenceStrings()

    // v1 ONLY. The table also carries the additive routes, whose messages are this server's
    // own because the reference has no such route to transcribe from: polls, app messages,
    // stickers, Send Later, scheduled messages, the webhook update. Holding those against
    // the reference would demand a string that cannot exist.
    let v1Handlers = Set(
      RouteCatalog.routes.filter { $0.group.apiVersion == 1 }.map(\.route.handlerID))

    var offenders: [String] = []
    var checked = 0
    for (handler, message) in SuccessMessages.byHandler.sorted(by: {
      $0.key.rawValue < $1.key.rawValue
    }) {
      guard v1Handlers.contains(handler) else { continue }
      checked += 1
      guard !reference.contains(message) else { continue }
      offenders.append("\(handler.rawValue): \"\(message)\"")
    }
    #expect(
      checked >= 30,
      "only \(checked) v1 entries were checked; the catalog lookup has stopped matching")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: """
          these envelope messages appear nowhere in the reference's routers, so this server \
          is sending a string no BlueBubbles client has ever received:

          \(offenders.joined(separator: "\n"))
          """)
    )
  }
}
