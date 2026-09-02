//  HelperVocabularyTests
//  The parts of the helper command vocabulary the compiler cannot check.
//
//  Most of it now checks itself. Each dispatch switches exhaustively over its own enum, so
//  adding a command that no helper implements does not compile — that property is verified by
//  the build, not here, and a test asserting it could never fail.
//
//  What is left over is what this file covers:
//
//    * The two vocabularies must stay disjoint. They address different processes on different
//      sockets, and the typed transport picks the target from the action's TYPE alone. A name
//      appearing in both enums would compile and route by whichever overload the call site
//      happened to resolve.
//    * Raw values are the wire. They must stay in the shape a shipped helper matches on.
//    * The client must keep originating commands as cases, not strings. Nothing stops someone
//      reaching for `request(action: "send-message", …)` again — the string overloads are
//      still there, because the frame decoder needs them.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@Suite("Helper vocabulary")
struct HelperVocabularyTests {

  private static var messages: Set<String> {
    Set(MessagesHelperAction.allCases.map(\.rawValue))
  }
  private static var faceTime: Set<String> {
    Set(FaceTimeHelperAction.allCases.map(\.rawValue))
  }

  /// The two helpers are separate processes on separate sockets. An action that existed in
  /// both enums would make the typed routing ambiguous at the call site.
  @Test("The two vocabularies share no command")
  func vocabulariesAreDisjoint() {
    let shared = Self.messages.intersection(Self.faceTime)
    #expect(shared.isEmpty, "a command cannot belong to both helpers")
  }

  /// `allCases` collapses duplicates silently if two cases carry the same raw value, and a
  /// duplicate would mean one of them is unreachable over the wire.
  @Test("Every command has a distinct raw value")
  func rawValuesAreUnique() {
    #expect(Self.messages.count == MessagesHelperAction.allCases.count)
    #expect(Self.faceTime.count == FaceTimeHelperAction.allCases.count)
  }

  /// The raw values are the protocol. A shipped helper matches on them, so their shape is
  /// fixed even though the case names are free to change.
  @Test("Commands are lower-case kebab, as the wire has always spelled them")
  func rawValuesAreKebabCase() {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz-")
    for raw in Self.messages.union(Self.faceTime) {
      #expect(
        raw.unicodeScalars.allSatisfy(allowed.contains),
        "\(raw) is not lower-case kebab"
      )
      #expect(!raw.hasPrefix("-") && !raw.hasSuffix("-"), "\(raw) has a stray dash")
    }
  }

  /// The string overloads on the transport cannot be removed — the frame decoder deals in raw
  /// names — so nothing but this stops a new command being sent as a literal again.
  @Test("The client originates no command as a raw string")
  func clientUsesTheTypedVocabulary() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appending(path: "Sources/BBPrivateAPI/PrivateAPIClient.swift"),
      encoding: .utf8
    )

    let literals = source.ranges(of: try Regex(#"action: "[a-z][a-z0-9-]*""#))
    #expect(
      literals.isEmpty,
      "the client sends a command as a string literal; use the typed overload instead"
    )
  }
}
