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
  /// Adding a section changes nothing for an archive that does not hold it: a newer server
  /// finds the section absent, which is indistinguishable from it never having been ticked,
  /// and an older one never sees its name. An archive that DOES hold a section the reading
  /// server does not know is refused whole, by `validate`, with the names it did not know;
  /// see there for why not partly read. A server built before that rule existed refuses it
  /// too, less helpfully: its manifest decode fails on the unknown name, with a decoding
  /// error, before anything is written.
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  /// What made it. Informational; see the header.
  public let serverVersion: String
  public let createdAt: Date
  /// The sections this server knows, in the order the archive lists them.
  public let sections: [ExportSection]
  /// The names the archive lists that this server does not know. Never written: an export
  /// lists only sections that exist.
  public let unrecognisedSections: [String]

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
    self.unrecognisedSections = []
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, serverVersion, createdAt, sections
  }

  /// Reads the section list as names, so one this server does not know is kept to be
  /// refused by name rather than failing the decode with a sentence about JSON.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    serverVersion = try container.decode(String.self, forKey: .serverVersion)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    let names = try container.decode([String].self, forKey: .sections)
    sections = names.compactMap(ExportSection.init(rawValue:))
    unrecognisedSections = names.filter { ExportSection(rawValue: $0) == nil }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(serverVersion, forKey: .serverVersion)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(sections, forKey: .sections)
  }

  public enum Failure: BBError, Equatable, CustomStringConvertible {
    case notAnExport
    case unsupportedSchema(Int)
    /// The archive holds sections this version does not know, by name.
    case unrecognisedSections([String])

    public var code: String {
      switch self {
      case .notAnExport: "export.not_an_export"
      case .unsupportedSchema: "export.unsupported_schema"
      case .unrecognisedSections: "export.unrecognised_sections"
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
      case .unrecognisedSections(let names):
        "This export holds parts this version of BlueBubbles cannot read ("
          + names.joined(separator: ", ") + "). Update before importing it."
      }
    }
  }

  /// Refuses a newer format, or a section this version does not know, rather than reading
  /// what it recognises.
  ///
  /// The tempting alternative — import the sections this version understands and skip the
  /// rest — is wrong for the same reason a partial settings import is: the person asked for
  /// their configuration back and would get most of it, with no way to tell which part was
  /// dropped. The format is checked first: a newer format may have renamed what it lists.
  public func validate() throws {
    guard schemaVersion <= Self.currentSchemaVersion else {
      throw Failure.unsupportedSchema(schemaVersion)
    }
    guard unrecognisedSections.isEmpty else {
      throw Failure.unrecognisedSections(unrecognisedSections)
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
