//  CommentReferencePolicyTests
//  A symbol or a file named in a comment or a document exists.
//
//  A comment that names a type, a member, a test or a file is a pointer, and a pointer is the
//  one kind of prose a reader acts on without reading further: they open the file, search for
//  the name, and when it is not there they conclude the thing is gone, or they go looking in
//  the wrong place. A rename updates every call site because the compiler insists; it updates
//  no comment and no document, so the pointers rot one rename at a time, and nothing reveals
//  it until somebody follows one. An agent follows them constantly, and weighs a confident
//  comment above the code beside it, which makes a stale name more expensive here than in a
//  codebase only people read. The first run of this scan found sixty: eleven of them tests
//  named as the thing enforcing a rule, where no test of that name existed.
//
//  THE RULE. Every inline code span (`` `Name` ``) in a whole-line Swift comment, or in the
//  prose of a governed document, that is shaped like a symbol must resolve:
//
//  - a bare `Name` is spelled somewhere in code, or is a file or a directory in the tree;
//  - a dotted `Type.member` names a type that is spelled in code (a file is not a type), and
//    where the type is declared in this repository, each member is spelled in code too;
//  - a call `name(label:)` names a function spelled in code;
//  - a `Name.ext` with a source extension is a file that exists in the tree;
//  - a name ending in `Tests` is held to the same rule, and reported in its own words, because
//    "enforced by `XTests`" is the claim that keeps every other rule in `CLAUDE.md` honest.
//
//  "Spelled in code" is any identifier in a line of Swift under `Sources/`, `Helper/`,
//  `Tests/`, `Tools/` and `Packaging/`, the ObjC under `Helper/`, the private-API header dumps
//  under `docs/headers/`, and the reference server's TypeScript. That is deliberately weaker
//  than "declared": it cannot tell a type from a variable of the same name, and it accepts a
//  name that survives only in a string literal. It is also what makes the check cheap enough
//  to run on every build and robust to how a declaration is spelled, and a rename is exactly
//  the case it catches: the old name disappears from code entirely.
//
//  CODE FONT IS A CLAIM. The consequence for a writer: a name that no longer exists, or that
//  never existed here (a design that was rejected, a type in another codebase), is written in
//  plain prose, which tells the reader it is not a live pointer. `docs/WRITING.md` says so.
//
//  WHAT IS NOT CHECKED, AND WHY. A root in all capitals is an acronym (`API`, `GUID`). A root
//  with two or more leading capitals that resolves nowhere is a framework name with a vendor
//  prefix (`NSUnarchiver`, `NWPath`, `IOPlatformUUID`); Apple's frameworks are not in this tree
//  and the dumps are targeted, so absence proves nothing. `BB` is this project's prefix and is
//  exempt from that exemption. A member of a type this repository does not declare is not
//  checked, because `Date.FormatStyle` is as correct as it is unspelled. A file with a
//  non-source extension (`.wflow`, `.vfx`, `.bundle`) is skipped, since those are never ours.
//  A name that is Apple's, JavaScript's or Dart's and never appears in this tree's code goes in
//  `external`, with a sentence saying whose it is, and an entry nothing names any more fails
//  the build so the list cannot grow stale.
//
//  `docs/SUBSCRIPTION_PLAN.md` is exempt by name: it is a plan that says in its own header
//  that the code is authoritative where the two disagree, and it names tests and types that
//  were built under other names or not at all.

import BBTestCore
import Foundation
import Testing

@Suite("Comments and documents name symbols that exist")
struct CommentReferencePolicyTests {

  static let namesExist = PolicyRule(
    rule: "A type, member, test or file named in code font, in a comment or a document, exists "
      + "under that name: code font is a claim the reader acts on.",
    fix: "Point the span at the current name; write a former or foreign name in plain prose; "
      + "or, if it is Apple's, JavaScript's or Dart's and code never spells it, add it to "
      + "`external` with whose it is.",
    home: #"docs/WRITING.md, "Code font is a claim that the thing exists""#)

  static let externalIsLive = PolicyRule(
    rule: "Every `external` entry is still consulted: one that nothing names any more, or that "
      + "the tree spells, is stale.",
    fix: "Remove the entry.",
    home: #"docs/WRITING.md, "Code font is a claim that the thing exists""#)

  // MARK: - What is exempt

  /// Names from outside this tree that comments and documents name and code never spells,
  /// each with whose it is. A key is a bare root, a full dotted path where the root is a type
  /// of ours that the other codebase happens to share, or a file name.
  static let external: [String: String] = [
    "ActionWildcard": "a grant scope in Shortcuts' own permissions database",
    "AfterFirstUnlock": "a keychain accessibility class, named without its kSec prefix",
    "AfterFirstUnlockThisDeviceOnly": "a keychain accessibility class, named without its prefix",
    "AnyView": "SwiftUI's type-erased view",
    "AppController": "a class inside FaceTime.app, not in the dumps",
    "AsyncBytes": "URLSession's byte stream",
    "AttributedBody.fromMap": "the Dart client's model, which shares our type's name",
    "Attributes": "the Dart client's attributedBody model",
    "BasicRequestContext": "Hummingbird's request context",
    "BinaryDecodingContainer": "an Apple FindMy framework type",
    "ConversationListFocusFilterAction": "Messages' own App Intent",
    "DateTime": "Dart's date type, which the client parses timestamps into",
    "EditedContent": "a key path the Dart client walks in the edited-message payload",
    "EnableReadReceiptForChatVersionID": "a Messages preference key",
    "File.writeAsString": "Dart's file API",
    "FileAttributeKey": "Foundation's file attribute keys",
    "FileRegion": "SwiftNIO's file region",
    "FindMyBase": "an Apple FindMy framework module",
    "FindMyCore": "an Apple FindMy framework module",
    "FindMyFriend.fromJson": "the Dart client's model, which shares our type's name",
    "FirebaseOptions": "Firebase's client configuration, built from google-services.json",
    "FormData": "the Dart client's multipart body",
    "GetNextEventMatchingMask": "a Carbon event function",
    "Images": "a capitalised value of the `only` filter, which the reference lower-cases",
    "LegacyGroupIdentifiers": "a Messages preference key",
    "MachServices": "a launchd job key",
    "MarkAsSpam": "a query name read from IMCore's disassembly",
    "MessageSummaryInfo": "the Dart client's edited-message model",
    "PascalCase": "a casing convention, not a type",
    "PlaySoundsKey": "a Messages preference key",
    "PowerManager": "a class inside FaceTime.app, not in the dumps",
    "QuotaFailure": "Google's quota error detail type",
    "ReactionTypes": "the Flutter client's tapback name table",
    "RichLink": "Apple's archived rich-link class inside a balloon payload",
    "RowDecodingError": "GRDB's row decoding error",
    "RunCurrentEventLoopInMode": "a Carbon event function",
    "ThisDeviceOnly": "a keychain accessibility class, named without its kSec prefix",
    "ThrottleInterval": "a launchd job key",
    "ToIntegerOrInfinity": "an ECMAScript abstract operation",
    "TypedGroup": "node-typedstream's wrapper for a typed group",
    "UpdateReleaseRequest": "a Firebase Rules API request type",
    "WebSocketRequestContext": "Hummingbird's WebSocket request context",
    "WhenUnlocked": "a keychain accessibility class, named without its kSec prefix",
    "WindowGroup": "SwiftUI's window scene",
    "BUNDLE.txt": "written by vm-share.sh into the VM share, never committed",
    "SPUUpdaterDelegate.h": "Sparkle's delegate header",
    "sendMulticast": "a firebase-admin method the reference calls",
  ]

  /// Documents the rule does not read, each with the reason.
  static let exemptDocuments: [String: String] = [
    "docs/SUBSCRIPTION_PLAN.md": "a plan whose header says the code is authoritative"
  ]

  /// A span whose last segment is one of these names a file. The ones in `sourceExtensions`
  /// are checked against the tree; the rest are skipped, since a `.wflow` or a `.bundle` is
  /// never ours.
  static let fileExtensions: Set<String> = [
    "swift", "md", "sh", "py", "ts", "tsx", "js", "m", "mm", "h", "c", "plist", "db", "app",
    "dylib", "json", "yml", "yaml", "conf", "txt", "csv", "log", "p12", "p8", "pem", "key",
    "env", "sql", "sqlite", "zip", "dmg", "pkg", "xcconfig", "resolved", "provisionprofile",
    "entitlements", "xml", "html", "framework", "bundle", "wflow", "vfx", "data", "strings",
    "xcassets", "icns", "png", "jpg", "jpeg", "heic", "gif", "mov", "mp4", "caf", "aiff",
    "scpt", "applescript", "appcast", "xcframework", "xcodeproj", "xcworkspace",
  ]

  /// Text files this repository holds, and so can be asked for. TypeScript is not among them:
  /// a file in the reference's tree is never named, which `ReferenceCitationPolicyTests` holds.
  static let sourceExtensions: Set<String> = [
    "swift", "md", "sh", "py", "js", "m", "mm", "h", "c", "plist", "json", "yml",
    "yaml", "conf", "txt", "csv", "sql", "xcconfig", "entitlements", "xml", "html", "strings",
    "applescript",
  ]

  /// Where a named file may live.
  static let fileRoots = [
    "Sources", "Helper", "Tests", "Tools", "Packaging", "docs", ".claude",
  ]

  // MARK: - Reading the tree

  /// A span shaped like a symbol: its root, its dotted members, and whether it is a call.
  struct Reference: Equatable {
    var root: String
    var members: [String]
    var isCall: Bool
    var endsInTests: Bool { (members.last ?? root).hasSuffix("Tests") }
    var path: String { ([root] + members).joined(separator: ".") }
  }

  /// Compiled once: building a `Regex` is far dearer than matching one, and this one is asked
  /// about every code span in the tree. `Regex` is not declared `Sendable`, but matching never
  /// mutates it, so sharing the one value between parallel tests is safe.
  nonisolated(unsafe) static let referencePattern =
    /^([A-Za-z][A-Za-z0-9]*)((?:\.[A-Za-z_][A-Za-z0-9_]*)*)(\((?:[A-Za-z_]+:|_:)*\))?$/

  /// A span is a reference when it is an identifier path with an optional call suffix:
  /// `Settings`, `Settings.renderable`, `ChatGUID.sameChat(_:_:)`, `withTimeout(_:operation:)`.
  static func reference(in span: String) throws -> Reference? {
    guard let match = try referencePattern.wholeMatch(in: span) else { return nil }
    let root = match.1
    let members = match.2.split(separator: ".").map(String.init)
    let isCall = match.3 != nil
    // A lower-case root is a symbol only as a call; a bare `foo` is as likely to be a
    // settings key, a column or a word the author set in code font.
    if root.first?.isLowercase == true && !isCall { return nil }
    return Reference(root: String(root), members: members, isCall: isCall)
  }

  /// The lines of a document outside fenced blocks, spans kept: a fence is a transcript or a
  /// command, and what it names is not a claim about this tree.
  static func prose(of text: String) -> [(number: Int, text: String)] {
    var lines: [(Int, String)] = []
    var inFence = false
    for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let line = String(raw)
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        inFence.toggle()
        continue
      }
      guard !inFence else { continue }
      lines.append((offset + 1, line))
    }
    return lines
  }

  /// Every backticked span on a line, in order.
  static func spans(in line: String) -> [String] {
    var found: [String] = []
    var current = ""
    var inSpan = false
    for character in line {
      if character == "`" {
        if inSpan, !current.isEmpty { found.append(current) }
        current = ""
        inSpan.toggle()
      } else if inSpan {
        current.append(character)
      }
    }
    return found
  }

  /// The identifiers in a line of code, as a Swift or C lexer would cut them.
  static func identifiers(in text: String, into set: inout Set<String>) {
    var unused: Set<String> = []
    identifiers(in: text, into: &set, declaring: &unused, recordsDeclarations: false)
  }

  /// The identifiers in a line of code, and in `declared` each one that follows a type
  /// keyword (`struct Name`, `enum Name`). One pass for both: a second walk over every line
  /// of Swift to find the declarations cost as much as the first.
  static func identifiers(
    in text: String, into set: inout Set<String>, declaring declared: inout Set<String>,
    recordsDeclarations: Bool = true
  ) {
    var current: [UInt8] = []
    var previous = ""
    func finish() {
      let identifier = String(decoding: current, as: UTF8.self)
      set.insert(identifier)
      if recordsDeclarations, typeKeywords.contains(previous) { declared.insert(identifier) }
      previous = identifier
      current.removeAll(keepingCapacity: true)
    }
    for byte in text.utf8 {
      let isStart = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
      let isContinue = isStart || (byte >= 48 && byte <= 57)
      if current.isEmpty ? isStart : isContinue {
        current.append(byte)
      } else if !current.isEmpty {
        finish()
      }
    }
    if !current.isEmpty { finish() }
  }

  /// What a name can resolve against.
  struct Vocabulary: Sendable {
    /// Every identifier in a line of code, in Swift, ObjC, a header dump or the reference.
    var spelled: Set<String> = []
    /// Every type name this repository declares, so a member can be held to it.
    var declared: Set<String> = []
    /// Every file stem and directory name under the source roots.
    var paths: Set<String> = []
    /// Every file name, with its extension, under `fileRoots` and at the repository root.
    var files: Set<String> = []

    func resolves(_ name: String) -> Bool { spelled.contains(name) || paths.contains(name) }
  }

  static let typeKeywords: Set<String> = [
    "struct", "class", "enum", "actor", "protocol", "typealias",
  ]

  /// The vocabulary, built once per test process: two tests read it, and building it reads
  /// every file in the tree.
  static func vocabulary() throws -> Vocabulary { try builtVocabulary.get() }

  private static let builtVocabulary = Result { try buildVocabulary() }

  private static func buildVocabulary() throws -> Vocabulary {
    var vocabulary = Vocabulary()
    // This file is left out: its `external` list spells every foreign name as a string
    // literal, which would make each of them "spelled in code" and the list unable to go stale.
    let swift = try SourceScanner.swiftFiles(
      under: "Sources", "Helper", "Tests", "Tools", "Packaging", minimum: 400
    ).filter { $0.name != "CommentReferencePolicyTests.swift" }
    // Its own name is still a pointer `CLAUDE.md` and the guides carry, so the file counts.
    vocabulary.paths.insert("CommentReferencePolicyTests")
    for file in swift {
      for line in file.codeLines {
        identifiers(in: line.code, into: &vocabulary.spelled, declaring: &vocabulary.declared)
      }
      vocabulary.paths.insert(file.url.deletingPathExtension().lastPathComponent)
      for component in file.path.split(separator: "/").dropLast() {
        vocabulary.paths.insert(String(component))
      }
    }
    // The manifest at the root is the one Swift file the roots above do not reach, and it is
    // where target names are spelled.
    identifiers(in: try SourceScanner.file("Package.swift").code, into: &vocabulary.spelled)
    // The ObjC helper, the private-API header dumps and the reference server: a comment that
    // names an IMCore class, a C function of ours, or a reference-side type is pointing at
    // something a reader can open, so each counts as spelled.
    let foreign =
      try SourceScanner.files(under: ["Helper"], extensions: ["m", "h", "c"], minimum: 1)
      + SourceScanner.files(under: ["docs/headers"], extensions: ["h"], minimum: 400)
      + SourceScanner.files(
        under: ["electron/packages/server/src"], extensions: ["ts"], minimum: 100)
    for file in foreign {
      identifiers(in: file.text, into: &vocabulary.spelled)
      vocabulary.paths.insert(file.url.deletingPathExtension().lastPathComponent)
    }
    // Every text file a comment could name, by its full name.
    let named =
      try SourceScanner.files(under: fileRoots, extensions: sourceExtensions, minimum: 1000)
      + SourceScanner.files(under: [""], extensions: sourceExtensions, recursive: false)
    for file in named { vocabulary.files.insert(file.name) }
    return vocabulary
  }

  /// Every governed document, with `docs/WRITING.md` read too: it names the terms the style
  /// scan bans, which is why that scan skips it, and that reason does not apply here.
  static func documents() throws -> [(path: String, text: String)] {
    let governed = try DocumentationStyleTests.documents()
    let writing = try SourceScanner.file("docs/WRITING.md")
    return (governed + [(writing.path, writing.text)])
      .filter { exemptDocuments[$0.path] == nil }
  }

  /// Every `(path, line, span)` a comment or a document carries, code spans only.
  static func spans() throws -> [(path: String, line: Int, span: String)] {
    var found: [(String, Int, String)] = []
    for document in try documents() {
      for line in prose(of: document.text) {
        for span in spans(in: line.text) { found.append((document.path, line.number, span)) }
      }
    }
    for file in try DocumentationStyleTests.sources() {
      for line in file.lines where line.isComment {
        for span in spans(in: line.comment) { found.append((file.path, line.number, span)) }
      }
    }
    return found
  }

  // MARK: - The rule

  /// Why a reference does not resolve, or nil when it does or is exempt. `used` collects the
  /// `external` keys consulted, so the list can be held to what is still named.
  static func problem(
    with reference: Reference, in vocabulary: Vocabulary, used: inout Set<String>
  ) -> String? {
    let root = reference.root

    /// The external list is consulted only once resolution has failed, so an entry for a
    /// name the tree does spell reads as stale and is removed.
    func unlessExternal(_ key: String, _ problem: String) -> String? {
      guard external[key] != nil else { return problem }
      used.insert(key)
      return nil
    }

    // A file: one that exists resolves outright; one of a kind this repository holds is
    // checked; the rest are skipped. A root this repository declares is a type, whatever its
    // member is called: `Webhook.json` is the record's projection, not a file, and it falls
    // through to the member check below.
    if let extensionName = reference.members.last, fileExtensions.contains(extensionName) {
      let name = reference.path
      if vocabulary.files.contains(name) { return nil }
      if !vocabulary.declared.contains(root) {
        guard sourceExtensions.contains(extensionName) else { return nil }
        return unlessExternal(name, "no file named `\(name)` exists in the tree")
      }
    }

    // An acronym, or a vendor-prefixed framework name that nothing in this tree spells.
    let leadingCapitals = root.prefix { $0.isUppercase }.count
    if leadingCapitals == root.count { return nil }
    if leadingCapitals >= 2 && !root.hasPrefix("BB") && !vocabulary.resolves(root) { return nil }

    if reference.isCall && reference.members.isEmpty {
      if vocabulary.spelled.contains(root) { return nil }
      return unlessExternal(root, "no function `\(root)` is spelled in code")
    }
    if reference.members.isEmpty {
      if vocabulary.resolves(root) { return nil }
      return unlessExternal(
        root,
        reference.endsInTests
          ? "no test `\(root)` exists; the rule it is said to enforce is unenforced"
          : "`\(root)` is spelled nowhere in code and names no file or directory")
    }
    // A dotted path: the root is a type or a module, so a file of that name is not enough.
    guard vocabulary.spelled.contains(root) else {
      let hint =
        vocabulary.paths.contains(root) ? "; a file of that name exists, name the type" : ""
      return unlessExternal(root, "`\(root)` is not a type or module spelled in code\(hint)")
    }
    // Members are checked only on a type this repository declares: Apple's members are not in
    // the tree, and `Date.FormatStyle` is as correct as it is unspelled.
    guard vocabulary.declared.contains(root) else { return nil }
    for member in reference.members where !vocabulary.spelled.contains(member) {
      return unlessExternal(
        reference.path,
        reference.endsInTests
          ? "no test `\(reference.path)` exists"
          : "`\(root)` has no member `\(member)` spelled in code; it may have been renamed")
    }
    return nil
  }

  @Test("The scan reads what it claims to read")
  func corpusIsRead() throws {
    let vocabulary = try Self.vocabulary()
    #expect(vocabulary.spelled.contains("ChatGUID"), "Swift code was not read")
    #expect(vocabulary.declared.contains("ChatGUID"), "declarations were not read")
    #expect(vocabulary.paths.contains("BBCore"), "directories were not read")
    #expect(vocabulary.spelled.contains("IMChat"), "the header dumps were not read")
    #expect(vocabulary.spelled.contains("BBSetArgument"), "the ObjC helper was not read")
    #expect(vocabulary.spelled.contains("MessageInterface"), "the reference was not read")
    #expect(vocabulary.files.contains("Package.swift"), "root-level files were not read")
    #expect(vocabulary.files.contains("SEARCH.md"), "documents were not read as files")
    #expect(vocabulary.files.contains("RouteTable.swift"), "sources were not read as files")

    let spans = try Self.spans()
    #expect(
      spans.count >= 5000,
      Comment(rawValue: "only \(spans.count) code spans were found; the scan is not reading"))
    #expect(spans.contains { $0.path == "CLAUDE.md" })
    #expect(spans.contains { $0.path.hasPrefix("Sources/") })
    #expect(spans.contains { $0.path == "docs/WRITING.md" }, "the writing guide is read here")
    #expect(!spans.contains { Self.exemptDocuments[$0.path] != nil }, "an exempt document was read")
  }

  @Test("Spans are cut and classified as the header says")
  func classification() throws {
    #expect(
      Self.spans(in: "a `Foo` and a `Bar.baz(_:)` and `not closed") == ["Foo", "Bar.baz(_:)"])
    #expect(
      try Self.reference(in: "Settings") == .init(root: "Settings", members: [], isCall: false))
    #expect(
      try Self.reference(in: "ChatGUID.sameChat(_:_:)")
        == .init(root: "ChatGUID", members: ["sameChat"], isCall: true))
    #expect(
      try Self.reference(in: "withTimeout(_:operation:)")
        == .init(root: "withTimeout", members: [], isCall: true))
    #expect(try Self.reference(in: "db_poll_interval") == nil, "a settings key is not a symbol")
    #expect(try Self.reference(in: "foo") == nil, "a bare lower-case word is not a symbol")
    #expect(try Self.reference(in: "--set") == nil)
    #expect(try Self.reference(in: "chat.db") == nil, "a lower-case root is not a type")
    #expect(try Self.reference(in: "…DidStartRunning") == nil, "a fragment is not a symbol")

    var vocabulary = Vocabulary()
    vocabulary.spelled = [
      "Settings", "renderable", "Date", "withTimeout", "HTTPAPIConfiguration", "AttributedBody",
    ]
    vocabulary.declared = ["Settings", "AttributedBody"]
    vocabulary.paths = ["HTTPServer", "SettingsLayout"]
    vocabulary.files = ["SettingsLayout.swift", "SEARCH.md"]
    var used: Set<String> = []
    func check(_ span: String) throws -> String? {
      let reference = try #require(try Self.reference(in: span), "\(span) is not a reference")
      return Self.problem(with: reference, in: vocabulary, used: &used)
    }
    #expect(try check("Settings") == nil)
    #expect(try check("Settings.renderable") == nil)
    #expect(try check("Settings.gone") != nil, "a member of our own type must be spelled")
    #expect(try check("Date.FormatStyle") == nil, "Apple's members are not checked")
    #expect(try check("SettingsLayout") == nil, "a file stem is a pointer")
    #expect(try check("HTTPServer.dispatch") != nil, "a file is not a type")
    #expect(try check("Vanished") != nil)
    #expect(try check("VanishedTests")?.contains("no test") == true)
    #expect(try check("withTimeout(_:operation:)") == nil)
    #expect(try check("vanished(_:)") != nil)
    #expect(try check("NSUnarchiver") == nil, "a vendor prefix that resolves nowhere is exempt")
    #expect(try check("BBVanished") != nil, "BB is ours, not a vendor prefix")
    #expect(try check("GUID") == nil, "an acronym")
    #expect(try check("SettingsLayout.swift") == nil, "a file that exists")
    #expect(try check("SEARCH.md") == nil)
    #expect(try check("Vanished.swift") != nil, "a file that does not")
    #expect(try check("Something.wflow") == nil, "a kind of file this tree never holds")
    vocabulary.spelled.insert("json")
    #expect(try check("Settings.json") == nil, "a member on a declared type is not a file")
    #expect(
      try check("AnyView") == nil && used.contains("AnyView"), "the external list is consulted")
    #expect(
      try check("AttributedBody.fromMap") == nil && used.contains("AttributedBody.fromMap"),
      "a full path can be external when the root is ours")
  }

  @Test("Every symbol a comment or document names exists")
  func namedSymbolsExist() throws {
    let vocabulary = try Self.vocabulary()
    var used: Set<String> = []
    var report: [String] = []
    for (path, line, span) in try Self.spans() {
      guard let reference = try Self.reference(in: span) else { continue }
      if let problem = Self.problem(with: reference, in: vocabulary, used: &used) {
        report.append("\(path):\(line): `\(span)`  \(problem)")
      }
    }
    #expect(report.isEmpty, Self.namesExist.comment(report))

    let stale = Set(Self.external.keys).subtracting(used).sorted()
    #expect(stale.isEmpty, Self.externalIsLive.comment(stale))
  }
}
