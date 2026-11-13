//  FrontEndPlumbingPolicyTests
//  How the two front ends, the app and the CLI, reach the server's storage and lifecycle.
//
//  Each rule here replaced a shape that had been copied by hand and had drifted, so each is a
//  scan: the copies compiled, and the one that forgot something compiled too. Comments are
//  skipped so a sentence explaining a rule is not read as breaking it, and every scan has a
//  floor on what it read, because a walk that finds no files passes.

import BBTestCore
import Foundation
import Testing

@Suite("Front-end plumbing policy")
struct FrontEndPlumbingPolicyTests {

  static let storageCollaborators = PolicyRule(
    rule: "A front end builds no exporter, importer or migration run from storage's fields: "
      + "`ServerComposition.Storage` hands them out.",
    fix: "Use `storage.exporter()`, `storage.importer()` or `storage.runMigration(_:)`.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let oneAttachmentList = PolicyRule(
    rule: "A child model is attached and detached through the one attachment list, never by "
      + "hand, so nothing is attached that the teardown forgets.",
    fix: "Go through `attachments.attach(_:_:)`, which records the detach in the same call.",
    home: #"Sources/BlueBubblesApp/CLAUDE.md, "attach and teardown are one list""#)

  static let conformingChildren = PolicyRule(
    rule: "Every model with an `attach` conforms to `ServerAttachable`, or it cannot go through "
      + "the attachment list and would be attached by hand.",
    fix: "Add the conformance in `ServerAttachments.swift`.",
    home: #"Sources/BlueBubblesApp/CLAUDE.md, "attach and teardown are one list""#)

  static let noContextDoor = PolicyRule(
    rule: "A facade door never hands back the `AppContext` itself, which a caller can recover "
      + "with `as? AppContext` from a capability existential.",
    fix: "Return the one thing the door opens, or a private forwarder.",
    home:
      #"Sources/BlueBubblesApp/CLAUDE.md, "Reach the server through a facade, never `AppContext`""#)

  static let contextInTheModel = PolicyRule(
    rule: "Only the model and the facades name `AppContext` or read a server's context.",
    fix: "Add a door to a facade in `ServerAccess.swift` and reach the state through it.",
    home:
      #"Sources/BlueBubblesApp/CLAUDE.md, "Reach the server through a facade, never `AppContext`""#)

  // MARK: - Storage

  /// `ServerComposition.Storage` hands out the exporter, the importer and a migration run.
  /// Each was built at its call site from storage's fields, three importers and three
  /// migration runs among them, so a collaborator added to one had to be remembered at
  /// every site.
  @Test("A front end builds no exporter, importer or migration run from storage's fields")
  func storageCollaboratorsComeFromStorage() throws {
    var offenders: [Offence] = []
    for directory in ["Sources/BlueBubblesApp", "Sources/BlueBubblesServer"] {
      offenders += try ViewPlumbingPolicyTests.scan(
        directory,
        matching: #"\bServerExporter\(|\bServerImporter\(|\bMigrationRunner\.run\("#,
        minimumFiles: 2)
    }
    #expect(offenders.isEmpty, Self.storageCollaborators.comment(offenders))
  }

  // MARK: - Attaching and detaching

  /// The names `AppModel` holds its attachable children under, from the conformances in
  /// `ServerAttachments.swift` and the properties in `AppModel.swift`.
  private static func attachableChildren() throws -> [String] {
    let conformances = try source("Sources/BlueBubblesApp/ServerAttachments.swift")
    let types = conformances.matches(of: try Regex(#"extension (\w+): ServerAttachable"#))
      .compactMap { $0.output[1].substring.map(String.init) }
    let model = try source("Sources/BlueBubblesApp/AppModel.swift")
    return try types.compactMap { type in
      model.firstMatch(of: try Regex("let (\\w+) = \(type)\\(\\)"))?
        .output[1].substring.map(String.init)
    }
  }

  /// Attach and teardown are ONE list. They were two, `start` and `tearDown`, and they had
  /// drifted: from `.migrationRequired`, onboarding, Home and the archive were attached to
  /// storage and never detached, because the teardown list only ran once there was a server.
  @Test("Every child model is attached through the attachment list, and only through it")
  func childrenAttachThroughOneList() throws {
    let children = try Self.attachableChildren()
    #expect(children.count >= 10, "found only \(children); the scan is not reading the model")

    let model = try Self.source("Sources/BlueBubblesApp/AppModel.swift")
    let unattached = children.filter { !model.contains("attachments.attach(\($0))") }
    #expect(
      unattached.isEmpty,
      Self.oneAttachmentList.comment(
        unattached.map { "Sources/BlueBubblesApp/AppModel.swift: `\($0)` is never attached" }))

    // And nothing reaches round the list: a direct attach is one nothing detaches, and a
    // direct detach is a second teardown list waiting to drift from the first.
    let pattern = #"\b("# + children.joined(separator: "|") + #")\.(attach|detach|finish)\("#
    let offenders = try ViewPlumbingPolicyTests.scan(
      "Sources/BlueBubblesApp", matching: pattern, except: ["ServerAttachments.swift"])
    #expect(offenders.isEmpty, Self.oneAttachmentList.comment(offenders))
  }

  /// A child that can attach but does not conform cannot go through the list, so it would be
  /// attached by hand. Every `func attach(` under `Models/` belongs to a conforming type.
  @Test("Every model with an attach conforms to ServerAttachable")
  func everyAttachingModelConforms() throws {
    let conformances = try Self.source("Sources/BlueBubblesApp/ServerAttachments.swift")
    var missing: [String] = []
    var scanned = 0
    try ViewPlumbingPolicyTests.forEachSource(in: "Sources/BlueBubblesApp/Models") {
      file, lines in
      let text = lines.joined(separator: "\n")
      guard text.contains("func attach(") else { return }
      scanned += 1
      let declared = text.matches(of: try Regex(#"final class (\w+)"#))
        .compactMap { $0.output[1].substring.map(String.init) }
      let attaching = declared.filter { conformances.contains("extension \($0): ServerAttachable") }
      if attaching.isEmpty { missing.append(file.path) }
    }
    #expect(scanned >= 10, "found only \(scanned) models with an attach")
    #expect(missing.isEmpty, Self.conformingChildren.comment(missing))
  }

  // MARK: - The container

  /// `AppContext` is private to the model. A facade door returning it as a capability
  /// existential (`var push: (any PushSetupProviding)? { context }`) handed the whole
  /// container to anyone who wrote `as? AppContext`; three doors did.
  @Test("No facade door hands back the context itself")
  func noDoorReturnsTheContext() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      "Sources/BlueBubblesApp", matching: #"\{\s*context\s*\}"#)
    #expect(offenders.isEmpty, Self.noContextDoor.comment(offenders))
  }

  /// Only the model and the facades name the container, and only the model reads it off the
  /// running server. `serverContext`, an internal accessor "not for views", was read from
  /// outside the model; it is gone, and this keeps a successor from appearing.
  @Test("Only the model and the facades name AppContext or read a server's context")
  func contextStaysInTheModel() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      "Sources/BlueBubblesApp",
      matching: #"\bAppContext\b|\bserverContext\b|server\??\.context\b"#,
      except: ["AppModel.swift", "ServerAccess.swift", "ServiceHealthObservation.swift"])
    #expect(offenders.isEmpty, Self.contextInTheModel.comment(offenders))
  }

  // MARK: - Source

  /// A file's code, comments removed, so a sentence naming a call is not read as making it.
  private static func source(_ path: String) throws -> String {
    try SourceScanner.file(path).code
  }
}
