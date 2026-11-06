//  ReferenceCitationPolicyTests
//  No comment and no document points into another repository's source.
//
//  This repository is the source of truth for what it ships. A comment that names a file in
//  the Electron reference, the Flutter client or the Objective-C helper, with or without a line
//  number, is a pointer a reader cannot act on from here and one that rots the moment that tree
//  moves; it also invites the next writer to argue from "the reference does it this way" about
//  things a client cannot observe. What another codebase does is stated as a fact: what the
//  reference puts on the WIRE is held by a recorded fixture or a parity test, what the client
//  reads is held by the wire-shape tests, and what the helper did is a method name.
//
//  THE RULE. In a whole-line Swift comment, and anywhere in a governed document (fenced blocks
//  included, since a transcript of another codebase is the thing being banned), no token
//  names a TypeScript or Dart file, no token names an Objective-C file with a `:line` suffix
//  or the shipping helper's main file, and no token names a path into one of those
//  repositories. A header dump committed under `docs/headers/` is a file in this tree and may
//  be named, line and all.
//
//  WHAT IS NOT CHECKED. Code and string literals: the parity tooling that reads the reference's
//  tree spells its paths in code, and that is its job. The words "reference", "Electron",
//  "the client" and "the Objective-C helper" are vocabulary, not pointers, and stay.

import BBTestCore
import Foundation
import Testing

@Suite("Comments and documents never point into the reference server's source")
struct ReferenceCitationPolicyTests {

  static let noPointers = PolicyRule(
    rule: "A Swift comment or a document never names a file in another repository: no TypeScript "
      + "or Dart file, no Objective-C file with a line number, and no path into the reference, "
      + "the client or the helper.",
    fix: "State what that codebase does as a fact and name the fixture, test or method that "
      + "holds it; drop the file and the line.",
    home: #"docs/WRITING.md, "State the wire as a fact""#)

  /// A TypeScript or Dart file name, optionally with a `:line` or `:from-to` suffix; an
  /// Objective-C file with one, or the shipping helper's main file by name; or a path into
  /// one of the three repositories. Not a domain label: a Tailscale hostname ends in
  /// `.ts.net`, so a `.ts` followed by a dot and a letter is left alone. Compiled once;
  /// matching never mutates it.
  nonisolated(unsafe) static let pointer = try! Regex(
    #"[A-Za-z0-9_./-]+\.(?:tsx?|dart)(?::[0-9]+(?:-[0-9]+)?)?(?![A-Za-z0-9])(?!\.[A-Za-z])"#
      + #"|[A-Za-z0-9_./-]+\.mm?:[0-9]+"#
      + #"|BlueBubblesHelper\.m|NetworkController\.m"#
      + #"|electron/packages|bluebubbles-(?:app|helper|composer)/|Messages/MacOS-11\+/"#)

  /// Documents the rule does not read, each with the reason.
  static let exemptDocuments: [String: String] = [
    "COMMERCIAL.md":
      "a licence statement, which names the directory the Apache-licensed code lives in; that "
      + "is a fact about licensing, not a pointer into the code"
  ]

  /// Every governed document, plus the Markdown at the repository root: the router, the
  /// contributor guide and the task list are read by every agent and are where a pointer is
  /// most likely to be copied from.
  static func documents() throws -> [(path: String, text: String)] {
    var seen: Set<String> = []
    var found: [(path: String, text: String)] = []
    let root = try SourceScanner.files(under: [""], extensions: ["md"], recursive: false)
      .map { ($0.path, $0.text) }
    for document in try CommentReferencePolicyTests.documents() + root
    where exemptDocuments[document.path] == nil && seen.insert(document.path).inserted {
      found.append(document)
    }
    return found
  }

  /// Every offending line, as `path:line: text`.
  static func offences() throws -> [String] {
    var found: [String] = []
    for file in try DocumentationStyleTests.sources() {
      for line in file.lines where line.isComment && line.comment.contains(pointer) {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        found.append("\(file.path):\(line.number): \(text)")
      }
    }
    for document in try documents() {
      let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false)
      for (offset, line) in lines.enumerated() where line.contains(pointer) {
        found.append("\(document.path):\(offset + 1): \(line)")
      }
    }
    return found
  }

  @Test("No comment or document names a file in the reference's tree")
  func nothingPointsIntoTheReference() throws {
    let offences = try Self.offences()
    #expect(offences.isEmpty, Self.noPointers.comment(offences))
  }

  @Test("The scan reads the router and the writing guide, and the pattern is the one described")
  func corpusAndPattern() throws {
    let paths = Set(try Self.documents().map(\.path))
    #expect(paths.contains("CLAUDE.md"))
    #expect(paths.contains("docs/WRITING.md"))
    #expect(paths.contains("TODO.md"))
    for path in Self.exemptDocuments.keys {
      #expect(try Repository.read(path).isEmpty == false, "an exempt document must still exist")
    }

    #expect("see `messageRouter.ts:144` for the shape".contains(Self.pointer))
    #expect("see `messageRouter.ts:141-142`".contains(Self.pointer))
    #expect("a component in `Navigation.tsx`".contains(Self.pointer))
    #expect("under electron/packages/server/src".contains(Self.pointer))
    #expect("the client's `full_sync_manager.dart` reads".contains(Self.pointer))
    #expect("ObjC: `editMessageInChat:` (BlueBubblesHelper.m:1142).".contains(Self.pointer))
    #expect("the queue (NetworkController.m:49)".contains(Self.pointer))
    #expect("under bluebubbles-app/lib/services".contains(Self.pointer))
    // A header dump committed here is a file in this tree, line and all.
    #expect(!"at `docs/headers/macos-14.6.1/IMTapback.h:21`".contains(Self.pointer))
    #expect(!"the lexer in `SourceScanner.swift`".contains(Self.pointer))
    // The bare extension is a word about TypeScript, not a file; a `.tsv` is not TypeScript;
    // a Tailscale hostname is a domain.
    #expect(!"a file with the `.ts` extension".contains(Self.pointer))
    #expect(!"the export is `rows.tsv`".contains(Self.pointer))
    #expect(!"reachable at `mac.tail1234.ts.net` once joined".contains(Self.pointer))
    #expect(!"https://mac.tail1234.ts.net:1234/api/v1".contains(Self.pointer))
  }
}
