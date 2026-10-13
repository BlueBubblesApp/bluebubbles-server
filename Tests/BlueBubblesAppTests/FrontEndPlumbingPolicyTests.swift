//  FrontEndPlumbingPolicyTests
//  How the two front ends, the app and the CLI, reach the server's storage and lifecycle.
//
//  Each rule here replaced a shape that had been copied by hand and had drifted, so each is a
//  scan: the copies compiled, and the one that forgot something compiled too. Comments are
//  skipped so a sentence explaining a rule is not read as breaking it, and every scan has a
//  floor on what it read, because a walk that finds no files passes.

import BBTestSupport
import Foundation
import Testing

@Suite("Front-end plumbing policy")
struct FrontEndPlumbingPolicyTests {

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
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "built by hand from storage's fields; use `storage.exporter()`, "
          + "`storage.importer()` or `storage.runMigration(_:)`:\n"
          + offenders.report))
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
    for child in children {
      #expect(
        model.contains("attachments.attach(\(child))"),
        "`\(child)` is never attached through `attachments.attach`, so nothing detaches it")
    }

    // And nothing reaches round the list: a direct attach is one nothing detaches, and a
    // direct detach is a second teardown list waiting to drift from the first.
    let pattern = #"\b("# + children.joined(separator: "|") + #")\.(attach|detach|finish)\("#
    let offenders = try ViewPlumbingPolicyTests.scan(
      "Sources/BlueBubblesApp", matching: pattern, except: ["ServerAttachments.swift"])
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a child model is attached or detached by hand; go through "
          + "`attachments.attach(_:_:)`, which records its detach:\n"
          + offenders.report))
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
    #expect(missing.isEmpty, "has an attach and no ServerAttachable conformance: \(missing)")
  }

  // MARK: - The container

  /// `AppContext` is private to the model. A facade door returning it as a capability
  /// existential (`var push: (any PushSetupProviding)? { context }`) handed the whole
  /// container to anyone who wrote `as? AppContext`; three doors did.
  @Test("No facade door hands back the context itself")
  func noDoorReturnsTheContext() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      "Sources/BlueBubblesApp", matching: #"\{\s*context\s*\}"#)
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a door returns the context; return the one thing it opens, or a private "
          + "forwarder:\n" + offenders.report))
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
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "reaches the server's container outside the model; add a door to a facade "
          + "in `ServerAccess.swift`:\n" + offenders.report))
  }

  // MARK: - Source

  /// A file's code, comments removed, so a sentence naming a call is not read as making it.
  private static func source(_ path: String) throws -> String {
    try SourceScanner.file(path).code
  }
}
