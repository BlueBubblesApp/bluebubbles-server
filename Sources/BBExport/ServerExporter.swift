//  ServerExporter
//  Writes the selected sections into a ZIP.
//
//  One JSON file per section plus `export.json`, flat, so the archive can be opened and
//  read by a person. That is a deliberate property and not an accident of convenience: an
//  export somebody cannot inspect is one they have to trust, and the whole point of the
//  per-section checkboxes is that they are deciding what leaves the machine.
//
//  **Only `secrets.enc` is opaque**, and only because it is encrypted; see
//  `SecretsEnvelope` for why the server password is both the gate and the key, and why a
//  server without one cannot produce that member at all.

import BBAppStore
import BBAuth
import BBPersistence
import BBSettings
import Foundation
import GRDB
import Logging

public struct ServerExporter: Sendable {

  private let database: AppDatabase
  private let settings: SettingsStore
  private let logger: Logger
  private let serverVersion: String

  public init(
    database: AppDatabase, settings: SettingsStore, serverVersion: String, logger: Logger
  ) {
    self.database = database
    self.settings = settings
    self.serverVersion = serverVersion
    self.logger = logger
  }

  /// What one export produced, for a caller that has to report it.
  public struct Report: Sendable {
    public let url: URL
    public let sections: [ExportSection]
    public let counts: [ExportSection: Int]
    public let byteCount: Int
  }

  /// Writes an archive of `sections` into `directory`.
  ///
  /// - Parameter serverPassword: required when `.secrets` is selected and ignored otherwise.
  ///   An empty one with `.secrets` selected is refused rather than downgraded to an export
  ///   without them: silently dropping the section somebody ticked is how a person ends up
  ///   believing they have a backup of something they do not.
  public func export(
    sections: Set<ExportSection>, to directory: URL, serverPassword: String = "",
    at moment: Date = Date()
  ) async throws -> Report {
    // The gate, and it is two questions rather than one. "Is a password set" decides
    // whether secrets may leave at all; "is this that password" decides whether the person
    // asking is entitled to them. Checking only the first would let anybody with a shell on
    // this Mac encrypt the credentials under a password of their choosing and walk away
    // with a file they can open — which is the export granting an ability the server did
    // not already give them.
    if sections.contains(.secrets) {
      let stored = await settings.string(forKey: Settings.password.key) ?? ""
      guard !stored.isEmpty else { throw SecretsEnvelope.Failure.noServerPassword }
      // Constant time, through the type that already does it. The comparison is against a
      // credential, and the fact that a timing leak here would be hard to exploit is not a
      // reason to write the version that has one.
      guard PasswordDigest(stored).constantTimeEquals(serverPassword) else {
        throw SecretsEnvelope.Failure.wrongPassword
      }
    }

    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // The staging directory holds the same material as the archive, in the clear apart from
    // the sealed member. It goes whatever happens.
    defer { try? FileManager.default.removeItem(at: staging) }

    let ordered = ExportSection.allCases.filter(sections.contains)
    var counts: [ExportSection: Int] = [:]

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    for section in ordered {
      let (data, count) = try await payload(
        for: section, encoder: encoder, password: serverPassword)
      try data.write(to: staging.appendingPathComponent(section.fileName), options: .atomic)
      counts[section] = count
    }

    let manifest = ExportManifest(
      serverVersion: serverVersion, createdAt: moment, sections: ordered)
    try encoder.encode(manifest)
      .write(to: staging.appendingPathComponent("export.json"), options: .atomic)

    let destination = directory.appendingPathComponent(ExportManifest.fileName(at: moment))
    try await ZipArchive.create(contentsOf: staging, into: destination)
    // `0600` for the same reason the search index is: it is derived from the server's own
    // state and has no business being readable by other accounts on this Mac.
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)

    let size =
      (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size]
      as? Int ?? 0
    // Counts and section names only. What is IN an export is the person's data, and a
    // support log is not the place for any of it.
    logger.info(
      "Wrote a server export",
      metadata: [
        "sections": .string(ordered.map(\.rawValue).joined(separator: ",")),
        "bytes": .stringConvertible(size),
      ])
    return Report(url: destination, sections: ordered, counts: counts, byteCount: size)
  }

  // MARK: - Sections

  private func payload(
    for section: ExportSection, encoder: JSONEncoder, password: String
  ) async throws -> (Data, Int) {
    switch section {
    case .settings:
      let rows = await portableSettings()
      return (try encoder.encode(rows), rows.count)

    case .webhooks:
      let rows = try await WebhookRepository(database: database).all()
      return (try encoder.encode(rows), rows.count)

    case .scheduledMessages:
      let rows = try await ScheduledMessageRepository(database: database).all()
      return (try encoder.encode(rows), rows.count)

    case .devices:
      let rows = try await DeviceRepository(database: database, logger: logger).all()
      return (try encoder.encode(rows), rows.count)

    case .contacts:
      // The contact, its addresses and whether it is switched off, by table. The contact
      // row alone is a name: every phone number and email is in `contact_address`.
      let tables = try await database.read { db -> [String: [ExportedRow]] in
        var tables: [String: [ExportedRow]] = [:]
        for table in ExportedRow.contactTables where try db.tableExists(table) {
          tables[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
            .map(ExportedRow.init(row:))
        }
        return tables
      }
      return (try encoder.encode(tables), tables[ExportedRow.contactTables[0]]?.count ?? 0)

    case .accessControl:
      let rows = try await database.read { db -> [String: [ExportedRow]] in
        [
          "allowed": try Row.fetchAll(db, sql: "SELECT * FROM allowed_client")
            .map(ExportedRow.init(row:)),
          "blocked": try Row.fetchAll(db, sql: "SELECT * FROM blocked_client")
            .map(ExportedRow.init(row:)),
        ]
      }
      return (try encoder.encode(rows), rows.values.reduce(0) { $0 + $1.count })

    case .clientBackups:
      // Read straight from the table rather than through `BackupRepository.all(kind:)`,
      // which answers one kind at a time. An export carries every kind a client has
      // stored, including ones this version has never heard of: the server does not parse
      // these blobs, so it has no basis for leaving one out.
      let rows = try await database.read { db in
        try Backup.order(Column("kind"), Column("name")).fetchAll(db)
      }
      return (try encoder.encode(rows), rows.count)

    case .secrets:
      let values = await secretValues()
      let sealed = try SecretsEnvelope.seal(
        try encoder.encode(values), withServerPassword: password)
      return (try encoder.encode(sealed), values.count)
    }
  }

  /// Every setting that may travel, read through its own declaration.
  ///
  /// `AnySetting.read` rather than the stored row, and the difference decides two things.
  ///
  /// It keeps the TYPE: a port read as a display string comes back as `"8080"`, writing
  /// that elsewhere stores a String where an `Int` was declared, and the setting then reads
  /// as its default with nothing saying why. `SettingBox` is the declaration's own
  /// vocabulary, so the value that goes out is the value that comes back.
  ///
  /// And it carries EFFECTIVE values, including ones never explicitly set. A restore should
  /// leave the target looking like the source; reading only stored rows would leave a
  /// target's own non-default value in place wherever the source sat at its default, which
  /// is a server matching neither machine.
  private func portableSettings() async -> [String: SettingValueBox] {
    var exported: [String: SettingValueBox] = [:]
    for setting in Settings.all
    where SettingPortability.isExportableSetting(setting.key, secretKeys: Settings.secretKeys) {
      exported[setting.key] = SettingValueBox(await setting.read(settings))
    }
    return exported
  }

  /// The secrets, read once, for sealing.
  ///
  /// `string(forKey:)` resolves a secret through the Keychain, so this is the one place in
  /// this module that materialises one — and it exists only to hand the values straight to
  /// `SecretsEnvelope.seal`. Nothing logs them and nothing keeps them.
  private func secretValues() async -> [String: String] {
    var values: [String: String] = [:]
    for key in Settings.secretKeys.sorted() {
      guard let secret = await settings.string(forKey: key), !secret.isEmpty else { continue }
      values[key] = secret
    }
    return values
  }
}

/// A `SettingBox` on disk: the value and which of the four kinds it is.
///
/// `SettingBox` is not `Codable` and should not become so for this — it is the settings
/// layer's in-memory vocabulary, and an archive format is not a reason to give it a wire
/// shape. This is that shape, here, where the format lives.
public struct SettingValueBox: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case bool, int, double, string }

  public let kind: Kind
  public let value: String

  public init(_ box: SettingBox) {
    switch box {
    case .bool(let value): (kind, self.value) = (.bool, value ? "true" : "false")
    case .int(let value): (kind, self.value) = (.int, String(value))
    case .double(let value): (kind, self.value) = (.double, String(value))
    case .string(let value): (kind, self.value) = (.string, value)
    }
  }

  /// Back to a box, or nil when the text does not parse as the kind it claims.
  ///
  /// Nil rather than a substituted default: a malformed entry in somebody's archive is
  /// something to report and skip, not to quietly replace with a value they never chose.
  public var box: SettingBox? {
    switch kind {
    case .bool: Bool(value).map(SettingBox.bool)
    case .int: Int(value).map(SettingBox.int)
    case .double: Double(value).map(SettingBox.double)
    case .string: .string(value)
    }
  }
}

/// A database row as plain JSON, for the tables this module reads generically.
///
/// Generic on purpose: contacts and the access-control lists are read by SQL rather than
/// through a typed repository because an export must carry a row as it IS, not as this
/// version's model happens to describe it. A column added later travels without this file
/// changing.
///
/// **Each value keeps its storage class.** Reading every column as `String?` trapped:
/// GRDB's subscript is `try! decode`, and an INTEGER column (`contact.source`,
/// `blocked_client.failure_count`, every autoincremented `id`) does not decode as text, so
/// exporting either section terminated the server.
struct ExportedRow: Codable {
  let values: [String: ExportedValue]

  /// The tables the contacts section carries, the contact table first: its rows are what
  /// the section counts, and it is written first on the way back in because the other two
  /// refer to it.
  static let contactTables = ["contact", "contact_address", "contact_disabled"]

  init(row: Row) {
    var captured: [String: ExportedValue] = [:]
    for column in row.columnNames {
      captured[column] = ExportedValue(row[column] as DatabaseValue)
    }
    values = captured
  }

  init(from decoder: any Decoder) throws {
    values = try [String: ExportedValue](from: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    try values.encode(to: encoder)
  }
}

/// One SQLite value, as JSON a person can read.
///
/// Text and NULL are themselves; integers and reals are numbers; a blob is an object naming
/// its encoding, so it cannot be mistaken for text on the way back in.
enum ExportedValue: Codable, Equatable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)

  init(_ value: DatabaseValue) {
    switch value.storage {
    case .null: self = .null
    case .int64(let integer): self = .integer(integer)
    case .double(let real): self = .real(real)
    case .string(let text): self = .text(text)
    case .blob(let data): self = .blob(data)
    }
  }

  var databaseValue: DatabaseValue {
    switch self {
    case .null: .null
    case .integer(let integer): integer.databaseValue
    case .real(let real): real.databaseValue
    case .text(let text): text.databaseValue
    case .blob(let data): data.databaseValue
    }
  }

  private enum BlobKey: String, CodingKey { case base64 }

  init(from decoder: any Decoder) throws {
    if let blob = try? decoder.container(keyedBy: BlobKey.self) {
      let encoded = try blob.decode(String.self, forKey: .base64)
      guard let data = Data(base64Encoded: encoded) else {
        throw DecodingError.dataCorruptedError(
          forKey: .base64, in: blob, debugDescription: "not base64")
      }
      self = .blob(data)
      return
    }
    let single = try decoder.singleValueContainer()
    if single.decodeNil() {
      self = .null
    } else if let integer = try? single.decode(Int64.self) {
      self = .integer(integer)
    } else if let real = try? single.decode(Double.self) {
      self = .real(real)
    } else {
      self = .text(try single.decode(String.self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    if case .blob(let data) = self {
      var blob = encoder.container(keyedBy: BlobKey.self)
      try blob.encode(data.base64EncodedString(), forKey: .base64)
      return
    }
    var single = encoder.singleValueContainer()
    switch self {
    case .null: try single.encodeNil()
    case .integer(let integer): try single.encode(integer)
    case .real(let real): try single.encode(real)
    case .text(let text): try single.encode(text)
    case .blob: break
    }
  }
}
