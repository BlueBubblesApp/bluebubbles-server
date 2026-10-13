//  NamingConventionTests
//  The naming rules in docs/NAMING.md, enforced where a test can see them.
//
//  These exist because the drift they catch was invisible until someone read four files
//  side by side. Two handlers had each documented a DIFFERENT convention as the house
//  convention: FindMy's said "the rest of this API is camelCase", FaceTime's said
//  snake_case, and both were describing v2. Nothing disagreed with either, because
//  nothing was checking.
//
//  It matters more than tidiness because `schemas.json` is INFERRED from the recorded
//  fixtures. Whatever a handler emits is promoted into the published OpenAPI document
//  without anyone reviewing it, so an inconsistent key is a permanent one by the time it
//  is noticed.
//
//  See docs/NAMING.md.

import BBTestSupport
import Foundation
import Testing

@Suite("Naming conventions")
struct NamingConventionTests {

  // MARK: - The v2 wire

  /// Every key v2 invents is `snake_case`.
  ///
  /// The allowlist is DERIVED, not written down: a camelCase key that also appears
  /// somewhere in `/api/v1` is an inherited entity field (a message, chat, handle or
  /// attachment coming out of the serializer both versions share) and those keep v1's
  /// casing wherever they surface. A camelCase key that appears ONLY under v2 is new
  /// surface with no such excuse.
  ///
  /// Deriving it this way means the allowlist maintains itself. Sharing more of the v1
  /// serializer widens it automatically; inventing a new camelCase field never does.
  @Test("v2 invents no camelCase keys")
  func v2IsSnakeCase() throws {
    let corpus = try FixtureCorpus.load()
    #expect(corpus.v1Keys.count > 100, "the v1 corpus is the allowlist; it cannot be empty")

    var offenders: [String: Set<String>] = [:]
    for fixture in corpus.fixtures where fixture.isV2 && !fixture.isPassthrough {
      for key in fixture.keys where Naming.isCamelCase(key) {
        guard !corpus.v1Keys.contains(key) else { continue }
        offenders[key, default: []].insert(fixture.name)
      }
    }

    #expect(
      offenders.isEmpty,
      """
      v2 emits camelCase keys that v1 does not define, so they are new surface \
      and must be snake_case (docs/NAMING.md):
      \(offenders.sorted { $0.key < $1.key }
        .map { "  \($0.key)  in \($0.value.sorted().joined(separator: ", "))" }
        .joined(separator: "\n"))
      """
    )
  }

  /// Routes whose response keys are not ours.
  ///
  /// `facetime/:id/debug` returns `state.mapValues(...)`: the helper's dictionary handed
  /// through unchanged, so the keys are whatever IMCore put there. One of them is literally
  /// `getActiveLinks(createdOnly:false)`, an Objective-C selector; there is no snake_case
  /// spelling of that, and inventing one would mean the debug route stopped reporting what
  /// the helper actually said, which is its entire purpose. It is also registered only in a
  /// development build.
  ///
  /// Listed by path rather than detected, so adding a passthrough route is a deliberate act
  /// with a line of justification next to it. See docs/NAMING.md § What is not ours to rename.
  static let passthroughRoutes = ["/api/v2/facetime/", "/debug"]

  /// v1 is NOT checked for casing, and must not be.
  ///
  /// Asserted rather than merely omitted: v1's inconsistency is the contract: clients
  /// switch on `isFromMe` and `server_version` and `SMS` in one response, so a future
  /// reader who "fixes" it by widening the test above to v1 should get a failure here
  /// explaining why not.
  @Test("v1 is exempt, and is inconsistent enough to prove the exemption is needed")
  func v1IsFrozen() throws {
    let corpus = try FixtureCorpus.load()
    let camel = corpus.v1Keys.filter(Naming.isCamelCase)
    let snake = corpus.v1Keys.filter(Naming.isSnakeCase)
    #expect(!camel.isEmpty && !snake.isEmpty, "v1 mixes both, and the parity harness owns it")
  }

  // MARK: - Storage and configuration

  /// The schema AFTER every migration, which is the only schema that exists on disk.
  ///
  /// Migrations are append-only, so a column's declaration is not its current name: the
  /// `create(table:)` that first declared `last_active` is frozen, and the rename to
  /// `last_active_at` lives in a later migration. Reading declarations alone would report
  /// the schema as it was on the day each table was added, which is a state no install has
  /// ever been in, and it would make renaming a column impossible to do correctly, since
  /// the fix and the failure would be in the same file arguing with each other.
  @Test("Every database column is snake_case, and every datetime says _at or _for")
  func schemaIsConsistent() throws {
    let source = try Sources.read("BBPersistence/AppDatabase.swift")

    // Declared, then renamed, in the order the migrator will run them.
    var columns: [(name: String, type: String)] = []
    let declaration = #"(?:\.column\(|\.add\(column: )"(\w+)", \.(\w+)\)"#
    for match in source.matches(of: try Regex(declaration)) {
      columns.append((String(match[1].substring!), String(match[2].substring!)))
    }
    let rename = #"\.rename\(column: "(\w+)", to: "(\w+)"\)"#
    for match in source.matches(of: try Regex(rename)) {
      let from = String(match[1].substring!)
      let to = String(match[2].substring!)
      for index in columns.indices where columns[index].name == from {
        columns[index].name = to
      }
    }

    let badCase = columns.map(\.name).filter {
      !Naming.isSnakeCase($0) && !Naming.isSingleWord($0)
    }
    let badTemporal =
      columns
      .filter { $0.type == "datetime" && !$0.name.hasSuffix("_at") && !$0.name.hasSuffix("_for") }
      .map(\.name)

    #expect(badCase.isEmpty, "columns are snake_case: \(badCase)")
    #expect(
      badTemporal.isEmpty,
      """
      a datetime column ends in `_at` (when it happened) or `_for` (when it is aimed at): \
      \(badTemporal)
      """
    )
  }

  @Test("Every settings key and feature flag id is snake_case")
  func configurationKeysAreConsistent() throws {
    let registry = try Sources.read("BBSettings/SettingsRegistry.swift")
    let flags = try Sources.read("BBSettings/FeatureFlags.swift")

    var offenders: [String] = []
    for match in registry.matches(of: try Regex(#"Setting<[^>]+>\(\s*\n?\s*"([^"]+)""#)) {
      let key = String(match[1].substring!)
      if !Naming.isSnakeCase(key) && !Naming.isSingleWord(key) { offenders.append(key) }
    }
    for match in flags.matches(of: try Regex(#"id: "([^"]+)""#)) {
      let id = String(match[1].substring!)
      if !Naming.isSnakeCase(id) && !Naming.isSingleWord(id) { offenders.append(id) }
    }

    #expect(offenders.isEmpty, "settings keys and flag ids are snake_case: \(offenders)")
  }

  /// Diagnostics reach clients through `?fields=extended`, so their keys are wire keys
  /// even though they are written like debug scratch.
  @Test("Diagnostic context keys are snake_case")
  func diagnosticContextIsConsistent() throws {
    var offenders: [String: String] = [:]
    var examined = 0
    for file in try Sources.allSwiftFiles() {
      let text = file.code
      guard text.contains("Diagnostics(") else { continue }
      examined += 1
      for match in text.matches(
        of: try Regex(#""([a-zA-Z_][a-zA-Z0-9_]*)": \.(?:string|int|bool|double|secret)\("#))
      {
        let key = String(match[1].substring!)
        if Naming.isCamelCase(key) { offenders[key] = file.name }
      }
    }
    #expect(examined > 0, "no file builds Diagnostics(...), so this checked nothing")
    #expect(
      offenders.isEmpty,
      "diagnostic context keys are snake_case: \(offenders.sorted { $0.key < $1.key })"
    )
  }
}

// MARK: - Shape tests

enum Naming {
  static func isSingleWord(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isLowercase || $0.isNumber }
  }

  static func isSnakeCase(_ s: String) -> Bool {
    guard s.contains("_"), let first = s.first, first.isLowercase else { return false }
    return s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
  }

  /// Lower camel, and only that. `SMS` and `__kIMMessagePartAttributeName` are neither
  /// camelCase nor anything else we name things: they are values lifted out of IMCore,
  /// and calling them camelCase would put them in front of a rule they cannot follow.
  static func isCamelCase(_ s: String) -> Bool {
    guard let first = s.first, first.isLowercase, !s.contains("_"), !s.contains("-") else {
      return false
    }
    return s.contains { $0.isUppercase }
  }
}

// MARK: - Reading the corpus

private enum Sources {
  /// A file under `Sources/`, comments removed: what the rules read are declarations.
  static func read(_ relative: String) throws -> String {
    try SourceScanner.file("Sources/\(relative)").code
  }

  /// Every Swift file under `Sources`, or a thrown error when that cannot be the whole tree.
  ///
  /// NEVER an empty list: a scan of nothing passes by finding nothing to object to. The floor
  /// is the difference between "no offenders" and "nothing read".
  static func allSwiftFiles() throws -> [SourceFile] {
    try SourceScanner.swiftFiles(under: "Sources", minimum: 101)
  }
}

private struct FixtureCorpus {
  struct Fixture {
    let name: String
    let isV2: Bool
    /// The response body is another system's dictionary, forwarded verbatim.
    let isPassthrough: Bool
    let keys: Set<String>
  }

  let fixtures: [Fixture]
  let v1Keys: Set<String>

  static func load() throws -> FixtureCorpus {
    let files = try SourceScanner.files(
      under: ["Fixtures/http"], extensions: ["json"], recursive: false)

    var fixtures: [Fixture] = []
    var v1: Set<String> = []
    for file in files {
      let data = Data(file.text.utf8)
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let response = root["response"] as? [String: Any],
        let body = response["body"] as? [String: Any],
        let value = body["value"]
      else { continue }

      // Only the response body. `recordedAt` and the request envelope belong to the
      // recorder, not to the API, and checking them would fail on the harness's own shape.
      var keys: Set<String> = []
      collect(value, into: &keys)

      let path = ((root["request"] as? [String: Any])?["path"] as? String) ?? ""
      let isV2 = path.hasPrefix("/api/v2/")
      if path.hasPrefix("/api/v1/") { v1.formUnion(keys) }
      let isPassthrough = NamingConventionTests.passthroughRoutes.allSatisfy(path.contains)
      fixtures.append(
        Fixture(
          name: file.name, isV2: isV2, isPassthrough: isPassthrough, keys: keys
        ))
    }
    return FixtureCorpus(fixtures: fixtures, v1Keys: v1)
  }

  private static func collect(_ value: Any, into keys: inout Set<String>) {
    if let object = value as? [String: Any] {
      for (key, nested) in object {
        keys.insert(key)
        collect(nested, into: &keys)
      }
    } else if let array = value as? [Any] {
      for element in array { collect(element, into: &keys) }
    }
  }
}
