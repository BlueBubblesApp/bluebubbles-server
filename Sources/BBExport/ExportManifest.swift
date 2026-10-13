//  ExportManifest
//  `export.json`: what this archive is, so an import can refuse it before it starts.
//
//  **Validated before anything is applied, and that ordering is the point.** An import that
//  reads the sections first and discovers a version problem halfway has already written
//  some of them. The manifest is small, it is read first, and a refusal costs nothing.
//
//  The server version is recorded for a person reading the file rather than for the code:
//  nothing branches on it, because "which release wrote this" is not the same question as
//  "can this be read", and answering the second with the first is how a format ends up
//  pinned to a release calendar. `schemaVersion` is the one that decides.

import BBCore
import Foundation

public struct ExportManifest: Codable, Sendable, Equatable {

  /// Bumped when an existing file's meaning changes, not when a section is added.
  ///
  /// Adding a section is backwards-compatible in both directions: an older server skips a
  /// member it does not recognise, and a newer one finds a section absent, which is
  /// indistinguishable from it never having been ticked.
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  /// What made it. Informational; see the header.
  public let serverVersion: String
  public let createdAt: Date
  public let sections: [ExportSection]

  public init(
    schemaVersion: Int = ExportManifest.currentSchemaVersion,
    serverVersion: String,
    createdAt: Date = Date(),
    sections: [ExportSection]
  ) {
    self.schemaVersion = schemaVersion
    self.serverVersion = serverVersion
    self.createdAt = createdAt
    self.sections = sections
  }

  public enum Failure: BBError, Equatable, CustomStringConvertible {
    case notAnExport
    case unsupportedSchema(Int)

    public var code: String {
      switch self {
      case .notAnExport: "export.not_an_export"
      case .unsupportedSchema: "export.unsupported_schema"
      }
    }
    public var domain: String { "Export" }
    public var title: String { "This is not an export this server can read" }
    /// The CLI prints this, so it is the same sentence the app shows.
    public var description: String { body }

    public var body: String {
      switch self {
      case .notAnExport:
        "This does not look like a BlueBubbles export: it has no export.json."
      case .unsupportedSchema(let version):
        "This export was written by a newer version of BlueBubbles (format \(version)). "
          + "Update before importing it."
      }
    }
  }

  /// Refuses a newer format rather than reading what it recognises.
  ///
  /// The tempting alternative — import the sections this version understands and skip the
  /// rest — is wrong for the same reason a partial settings import is: the person asked for
  /// their configuration back and would get most of it, with no way to tell which part was
  /// dropped.
  public func validate() throws {
    guard schemaVersion <= Self.currentSchemaVersion else {
      throw Failure.unsupportedSchema(schemaVersion)
    }
  }

  /// The name an export is written under.
  ///
  /// Sortable, second-resolution, and no colons: a Finder-visible name with `:` in it is
  /// shown to the user with slashes instead, so two exports a minute apart would look like
  /// paths.
  public static func fileName(at moment: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return "bluebubbles-export-\(formatter.string(from: moment)).zip"
  }
}
