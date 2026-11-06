//  ServerImporter
//  Reads an archive back into a server.
//
//  **Inspect, then apply, and they are separate calls.** `inspect` opens the archive, checks
//  the manifest and reports what is in it without writing anything; `apply` takes that
//  inspection and commits. A UI shows the first as a preview and a CLI prints it, so nobody
//  finds out what an import contained by running it.
//
//  **Sections are REPLACED, not merged.** A merge sounds gentler and is worse: importing a
//  webhook list that is missing one you deleted on the old server would leave it here, so
//  the result would match neither machine. Replace is a state somebody can reason about —
//  "this section now matches the archive" — and it is what a person restoring a backup
//  means. Settings are one exception: those are written key by key over whatever is
//  there, because a settings file is a partial view by construction (`SettingPortability`
//  excludes a dozen keys) and clearing the rest would reset this server's own address,
//  migration state and onboarding. The credential sections are the other: each document the
//  archive carries replaces this server's, and one it does not carry is left alone, because
//  an export never writes an absent credential and a restore must not read one as "remove".
//
//  **A key is accepted only from the file its route names.** `ExportedKeys` lists what an
//  archive may carry and `SettingPortability.Route` says which file each one belongs in, so
//  a secret or a tunnel hostname found in `settings.json`, or an ordinary setting found in
//  the sealed map, is refused rather than written: it is not what this server exports, and
//  writing it would take a value round the storage its declaration chose.

import BBAppStore
import BBAuth
import BBCore
import BBPersistence
import BBServiceKit
import BBSettings
import Foundation
import GRDB
import Logging

/// A server running over the storage an import writes into, and what the import has to do
/// about what that server holds in memory.
///
/// The record sections are tables, and a running server keeps copies of two of them. The
/// copies differ in kind, and so does what an import does about each:
///
///   - a CACHE (`ContactIndex`'s lookups) only goes stale. The section is written to the
///     table and the server is told, through `sectionWasRestored`, and reads it again;
///   - an AUTHORITY (`AccessControlService`'s lists) rewrites its table from memory on its
///     next change, so a table written beneath it is overwritten by the next block. The
///     section is written THROUGH it instead, by `runningAccessControl`. A reload after a
///     write beneath it cannot be made safe: a block landing between the two is written
///     from the old lists and read back as the new ones.
///
/// Held by the storage and attached to by whatever server is built over it, so with no
/// server the answers are nil and nothing: the CLI importing into a stopped server writes
/// the tables, and the next start reads them.
public protocol RestoreTarget: Sendable {
  /// The running server's access controller, or nil when no server runs over this storage.
  func runningAccessControl() async -> AccessControlService?
  /// Called as soon as `section` has been written, before the next one starts, and also
  /// when it failed part-way, since it may have written some of its tables.
  func sectionWasRestored(_ section: ExportSection) async
}

public struct ServerImporter: Sendable {

  private let database: AppDatabase
  private let settings: SettingsStore
  private let keys: ExportedKeys
  private let target: (any RestoreTarget)?
  private let credentials: (any CredentialVault)?
  private let logger: Logger

  /// - Parameter services: the manifests whose fields an archive may write. See
  ///   `ExportedKeys`.
  /// - Parameter target: the server running over `database`, if any; see `RestoreTarget`.
  ///   Nil only where nothing can be.
  /// - Parameter credentials: where the Firebase documents and the TLS certificate are
  ///   restored to. Nil only where neither is imported; ticking one without it is refused.
  public init(
    database: AppDatabase, settings: SettingsStore, services: [ServiceManifest],
    target: (any RestoreTarget)? = nil, credentials: (any CredentialVault)? = nil,
    logger: Logger
  ) {
    self.database = database
    self.settings = settings
    self.keys = ExportedKeys(services: services)
    self.target = target
    self.credentials = credentials
    self.logger = logger
  }

  /// What an archive holds, read without applying any of it.
  public struct Inspection: Sendable {
    public let manifest: ExportManifest
    /// How many records each unsealed section carries. A sealed one cannot be counted
    /// without the password.
    public let counts: [ExportSection: Int]
    /// Where the archive was unpacked. The caller removes it; `apply` does not.
    public let directory: URL

    public var sections: [ExportSection] { manifest.sections }

    /// Whether the archive holds a sealed section, and therefore whether importing all of
    /// it needs a password.
    public var hasSealedSections: Bool { sections.contains(where: \.isSealed) }
  }

  public enum Failure: BBError, Equatable, CustomStringConvertible {
    /// The manifest lists the section and the archive has no file for it.
    case sectionMissing(ExportSection)
    /// The section was ticked and the archive's manifest does not list it.
    case sectionNotInArchive(ExportSection)
    case passwordRequired
    /// A credential section was ticked on an importer built without a vault.
    case noCredentialVault(ExportSection)

    public var code: String {
      switch self {
      case .sectionMissing: "export.section_missing"
      case .sectionNotInArchive: "export.section_not_in_archive"
      case .passwordRequired: "export.password_required"
      case .noCredentialVault: "export.no_credential_vault"
      }
    }
    public var domain: String { "Export" }
    public var title: String { "The export could not be imported" }
    /// The CLI prints this, so it is the same sentence the app shows.
    public var description: String { body }

    public var body: String {
      switch self {
      case .sectionMissing(let section):
        "This export lists \"\(section.title)\" but does not contain it. The file is "
          + "incomplete."
      case .sectionNotInArchive(let section):
        "This export does not contain \"\(section.title)\", so there is nothing to import "
          + "for it. Untick it, or choose an export that has it."
      case .passwordRequired:
        "This export contains passwords, keys or credentials, which are encrypted. Enter "
          + "the server password that was used when it was made."
      case .noCredentialVault(let section):
        "\"\(section.title)\" cannot be imported from here, because nothing can write the "
          + "Keychain items it is kept in."
      }
    }
  }

  /// Unpacks and validates, writing nothing.
  ///
  /// The caller owns `Inspection.directory` and must remove it — it holds the archive's
  /// contents in the clear, which is the same material the export was careful about. Until
  /// an `Inspection` is handed back nobody else knows the directory exists, so EVERY way
  /// out of here before that removes it: a failed extraction, a manifest that will not
  /// decode or names a newer format, a missing section. One `catch` rather than a removal
  /// beside each `throw`, because a removal beside each throw is how a `try` added between
  /// two of them leaves somebody's settings in `$TMPDIR`.
  public func inspect(_ archive: URL) async throws -> Inspection {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-import-\(UUID().uuidString)", isDirectory: true)
    do {
      try await ZipArchive.extract(archive, into: directory)
      return try read(directory)
    } catch {
      discard(directory)
      throw error
    }
  }

  /// The manifest and the per-section counts of an extracted archive.
  private func read(_ directory: URL) throws -> Inspection {
    let manifestURL = directory.appendingPathComponent("export.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw ExportManifest.Failure.notAnExport
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      ExportManifest.self, from: try Data(contentsOf: manifestURL))
    // BEFORE anything is counted or read. See the type's own header.
    try manifest.validate()

    // Every listed section, the sealed ones included: a manifest promising secrets with no
    // `secrets.enc` beside it is as incomplete as one missing its settings, and finding out
    // at apply would be finding out after the other sections had been written.
    var counts: [ExportSection: Int] = [:]
    for section in manifest.sections {
      let url = directory.appendingPathComponent(section.fileName)
      // A read that fails is reported as the section missing, which is what it is to the
      // person holding the file.
      guard let data = try? Data(contentsOf: url) else {
        throw Failure.sectionMissing(section)
      }
      guard !section.isSealed else { continue }
      counts[section] = Self.count(in: data, for: section)
    }

    return Inspection(manifest: manifest, counts: counts, directory: directory)
  }

  /// Removes an extraction nobody will be handed, saying so when it cannot.
  ///
  /// Not thrown: the failure the caller is about to see is the one that explains what
  /// happened to their import. Logged instead, at the level that gets read, because what is
  /// left behind is the archive's contents in the clear. The path is a temporary folder
  /// named for a UUID, and says nothing about the person.
  private func discard(_ directory: URL) {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      logger.error(
        "Could not remove an import's unpacked copy",
        metadata: [
          "directory": .string(directory.path),
          "error": .string(DiagnosticText.sentence(for: error)),
        ])
    }
  }

  /// A key the archive carried that this server declined, and why.
  ///
  /// The reason is part of the record because the four are different news: a key that
  /// describes another server is the import working, and a value this server's own rules
  /// refuse is something the person may want to set by hand.
  public struct SkippedSetting: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
      /// It describes the server it came from (`SettingPortability.nonPortable`).
      case describesAnotherServer
      /// Not a key this server exports, or found in a file its route does not name.
      case notExported
      /// The value is not the kind the key holds, or is empty where no export writes one.
      case malformed
      /// This server's own rules refused the value; the sentence says which.
      case refused(String)
    }

    public let key: String
    public let reason: Reason

    /// The reason as a phrase to put after the key.
    public var explanation: String {
      switch reason {
      case .describesAnotherServer: "describes the server it came from"
      case .notExported: "not something this server exports"
      case .malformed: "not a value this setting can hold"
      case .refused(let sentence): sentence
      }
    }
  }

  /// A key whose value this server accepted and then could not store: the Keychain refused,
  /// or the database did. Not a skip, because nothing about the archive was wrong, and the
  /// key still holds whatever this server had before.
  public struct FailedSetting: Sendable, Equatable {
    public let key: String
    /// Through `DiagnosticText`, so it is a sentence rather than a Swift enum.
    public let message: String
  }

  /// What one import changed.
  public struct Report: Sendable {
    public let applied: [ExportSection]
    public let counts: [ExportSection: Int]
    /// Keys the archive carried that this server declined, each with why.
    public let skippedSettings: [SkippedSetting]
    /// Keys this server meant to write and could not.
    public let failedSettings: [FailedSetting]
  }

  /// Applies the chosen sections.
  ///
  /// - Parameter sections: a subset of what the archive holds. Ticking a section the
  ///   archive does not contain is refused rather than ignored.
  /// - Parameter serverPassword: needed only for a sealed section, and it is the password
  ///   that was typed when the export was MADE — not necessarily this server's.
  @discardableResult
  public func apply(
    _ inspection: Inspection, sections: Set<ExportSection>, serverPassword: String = ""
  ) async throws -> Report {
    // Asked of what was TICKED, before anything is written. Filtering the ticks by the
    // manifest first and then asking the manifest is a check that cannot fire.
    for section in ExportSection.allCases
    where sections.contains(section) && !inspection.manifest.sections.contains(section) {
      throw Failure.sectionNotInArchive(section)
    }
    let ordered = inspection.sections.filter(sections.contains)
    if ordered.contains(where: \.isSealed), serverPassword.isEmpty {
      throw Failure.passwordRequired
    }
    if credentials == nil,
      let section = ordered.first(where: { $0 == .firebaseCredentials || $0 == .tlsCertificate })
    {
      throw Failure.noCredentialVault(section)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var counts: [ExportSection: Int] = [:]
    var skipped: [SkippedSetting] = []
    var failed: [FailedSetting] = []

    // Every sealed section is opened before ANY section is written. They come last, so a
    // wrong password found when the loop reached them was found after every other ticked
    // section had already replaced this server's.
    var opened: [ExportSection: Data] = [:]
    for section in ordered where section.isSealed {
      let url = inspection.directory.appendingPathComponent(section.fileName)
      let envelope = try decoder.decode(SecretsEnvelope.self, from: try Data(contentsOf: url))
      opened[section] = try envelope.open(withPassword: serverPassword)
    }

    for section in ordered {
      let url = inspection.directory.appendingPathComponent(section.fileName)
      // A sealed section's plaintext, or an unsealed section's file.
      let data = try opened[section] ?? Data(contentsOf: url)
      // Announced as soon as the section is written, not once the whole import is: the
      // sections after it (the sealed one decrypts and writes to the Keychain) can take
      // seconds, and a server answering from a stale copy for that long is a server
      // answering wrongly. A section that failed part-way is announced too, since it may
      // have written some of its tables, and reading them again is right whatever they
      // hold; the ones before it stay written either way.
      let outcome: SectionOutcome
      do {
        outcome = try await restore(
          section, from: data, decoder: decoder, restoringDevices: ordered.contains(.devices))
      } catch {
        await target?.sectionWasRestored(section)
        throw error
      }
      await target?.sectionWasRestored(section)
      counts[section] = outcome.applied
      skipped.append(contentsOf: outcome.skipped)
      failed.append(contentsOf: outcome.failed)
    }

    logger.info(
      "Imported a server export",
      metadata: [
        "sections": .string(ordered.map(\.rawValue).joined(separator: ",")),
        "skippedSettings": .stringConvertible(skipped.count),
      ])
    if !failed.isEmpty {
      // Keys only: a setting's storage key is not personal, and its value is not logged.
      logger.error(
        "An import could not store some settings",
        metadata: ["keys": .string(failed.map(\.key).sorted().joined(separator: ","))])
    }
    return Report(
      applied: ordered, counts: counts,
      skippedSettings: skipped.sorted { $0.key < $1.key },
      failedSettings: failed.sorted { $0.key < $1.key })
  }

  // MARK: - Sections

  /// What one section did: how many records it wrote and, for the two settings-shaped
  /// sections, which keys it declined or could not store.
  private struct SectionOutcome {
    var applied = 0
    var skipped: [SkippedSetting] = []
    var failed: [FailedSetting] = []

    /// A credential section's outcome, in the report's terms: a document the vault refused
    /// is a skip, with the vault's sentence, and one it could not store is a failure, as
    /// for a setting.
    static func credentials(_ restore: CredentialRestore) -> SectionOutcome {
      SectionOutcome(
        applied: restore.stored.count,
        skipped: restore.refused.map {
          SkippedSetting(key: $0.document.rawValue, reason: .refused($0.sentence))
        },
        failed: restore.failed.map {
          FailedSetting(key: $0.document.rawValue, message: $0.sentence)
        })
    }

    /// Checks one value against its key's own rules, then writes it, and records which of
    /// the two said no.
    ///
    /// Two steps because the two answers are different news. A value the rules refuse is
    /// the archive's problem and a skip; a store that could not keep an acceptable value is
    /// this server's problem and a failure. A write throws both, and a validator may throw
    /// any error type, so the error alone cannot tell them apart.
    mutating func restore(
      _ entry: ExportedKeys.Entry, _ box: SettingBox, into settings: SettingsStore
    ) async {
      let write: @Sendable () async throws -> Void
      do {
        write = try Self.checked(entry, box, into: settings)
      } catch SettingsError.typeMismatch {
        skipped.append(SkippedSetting(key: entry.key, reason: .malformed))
        return
      } catch {
        skipped.append(
          SkippedSetting(key: entry.key, reason: .refused(DiagnosticText.sentence(for: error))))
        return
      }
      do {
        try await write()
        applied += 1
      } catch {
        failed.append(FailedSetting(key: entry.key, message: DiagnosticText.sentence(for: error)))
      }
    }

    /// The write for an accepted value, or the refusal.
    ///
    /// A declared setting through its declaration's own rules (`AnySetting.check`, and then
    /// its writer, which checks again). A service field through `FieldValidation`, the
    /// field's own declaration of what it accepts and the rule its form holds a person to,
    /// stored where the field says: the Keychain or the database. `disabled_services` is
    /// text and nothing else.
    private static func checked(
      _ entry: ExportedKeys.Entry, _ box: SettingBox, into settings: SettingsStore
    ) throws -> @Sendable () async throws -> Void {
      let key = entry.key
      switch entry.origin {
      case .declared(let declaration):
        try declaration.check(box)
        return { try await declaration.write(settings, box) }
      case .field(let field):
        let value = try text(of: box, key: key)
        if let failure = field.validation?.failure(for: value) {
          throw SettingsError.validationFailed(key: key, reason: failure)
        }
        let isSecret = field.isSecret
        return { try await settings.set(value, forKey: key, isSecret: isSecret) }
      case .enablement:
        let value = try text(of: box, key: key)
        return { try await settings.set(value, forKey: key, isSecret: false) }
      }
    }

    /// A field's value and `disabled_services` are text; an archive claiming another kind
    /// for one is refused rather than coerced.
    private static func text(of box: SettingBox, key: String) throws -> String {
      guard case .string(let value) = box else {
        throw SettingsError.typeMismatch(
          key: key, expected: "String", found: String(describing: box))
      }
      return value
    }
  }

  /// Writes one section.
  ///
  /// `data` is an unsealed section's file, or a sealed section's plaintext, which `apply`
  /// opened. The envelope proves only who sealed it: what is inside is a file from outside
  /// this server all the same, so it decodes into the shape an export writes or the section
  /// fails, and each case then holds the values to their own rules.
  private func restore(
    _ section: ExportSection, from data: Data, decoder: JSONDecoder, restoringDevices: Bool
  ) async throws -> SectionOutcome {
    switch section {
    case .settings:
      return try await restoreSettings(from: data, decoder: decoder)

    case .secrets:
      return try await restoreSealed(decoder.decode([String: String].self, from: data))

    case .firebaseCredentials:
      // Checked by `apply` before anything was written.
      guard let credentials else { throw Failure.noCredentialVault(section) }
      let documents = try decoder.decode(FirebaseCredentials.self, from: data)
      // A section an export writes always holds a document; one that holds none, or an
      // empty one, is a file asking to clear this server's credentials, which no export
      // means.
      let present = [documents.serviceAccount, documents.clientConfig].compactMap { $0 }
      guard !present.isEmpty, present.allSatisfy({ !$0.isEmpty }) else {
        return SectionOutcome(skipped: [
          SkippedSetting(key: section.rawValue, reason: .malformed)
        ])
      }
      return .credentials(
        await credentials.restore(documents, keepingDevices: restoringDevices))

    case .tlsCertificate:
      guard let credentials else { throw Failure.noCredentialVault(section) }
      let certificate = try decoder.decode(CertificateCredentials.self, from: data)
      return .credentials(await credentials.restore(certificate))

    case .webhooks:
      return SectionOutcome(
        applied: try await replace(Webhook.self, id: \.id, from: data, decoder: decoder))

    case .scheduledMessages:
      return SectionOutcome(
        applied: try await replace(
          ScheduledMessage.self, id: \.id, from: data, decoder: decoder))

    case .devices:
      return SectionOutcome(
        applied: try await replace(Device.self, id: \.id, from: data, decoder: decoder))

    case .clientBackups:
      return SectionOutcome(
        applied: try await replace(Backup.self, id: \.id, from: data, decoder: decoder))

    case .contacts:
      let tables = try decoder.decode([String: [ExportedRow]].self, from: data)
      // One transaction for the three, so a refused address cannot leave the contacts
      // replaced and their numbers gone. In order: the other two refer to the first.
      try await database.write { db in
        for table in ExportedRow.contactTables.reversed() where try db.tableExists(table) {
          try db.execute(sql: "DELETE FROM \(table)")
        }
        for table in ExportedRow.contactTables {
          try Self.insert(tables[table] ?? [], into: table, db: db)
        }
      }
      return SectionOutcome(applied: tables[ExportedRow.contactTables[0]]?.count ?? 0)

    case .accessControl:
      // Decoded into records before anything is written, so a row this server cannot read
      // refuses the section with both lists as they were.
      let groups = try decoder.decode([String: [ExportedRow]].self, from: data)
      let blocked = try (groups["blocked"] ?? []).map { try BlockedClient(row: $0.row) }
      let allowlist = try (groups["allowed"] ?? []).map { try AllowedClient(row: $0.row) }
      // Through the running server's controller when there is one; see `RestoreTarget`.
      if let live = await target?.runningAccessControl() {
        try await live.replaceAdministeredLists(blocked: blocked, allowlist: allowlist)
      } else {
        try await AccessControlStore(database: database)
          .replace(blocked: blocked, allowlist: allowlist)
      }
      return SectionOutcome(applied: blocked.count + allowlist.count)
    }
  }

  /// Replaces a record table with the archive's rows, in one transaction.
  ///
  /// Each row's `id` is cleared, so the database assigns it as it does for any new row.
  /// Returns how many rows were written.
  private func replace<Record: Decodable & PersistableRecord & Sendable>(
    _ type: Record.Type, id: WritableKeyPath<Record, Int64?>, from data: Data,
    decoder: JSONDecoder
  ) async throws -> Int {
    let rows = try decoder.decode([Record].self, from: data).map { row in
      var row = row
      row[keyPath: id] = nil
      return row
    }
    try await database.write { db in
      try db.execute(sql: "DELETE FROM \(Record.databaseTableName)")
      for row in rows { try row.insert(db) }
    }
    return rows.count
  }

  /// Settings are written key by key rather than replacing the table. See the header.
  private func restoreSettings(from data: Data, decoder: JSONDecoder) async throws
    -> SectionOutcome
  {
    let values = try decoder.decode([String: SettingValueBox].self, from: data)
    var outcome = SectionOutcome()

    for (key, stored) in values.sorted(by: { $0.key < $1.key }) {
      // Checked again HERE, on the way in, and not only on the way out. An archive is a
      // file from outside this server: it may have been written by a version whose
      // portability list was shorter, or edited by hand. Trusting the exporter's
      // judgement about somebody else's file is how `server_address` gets imported.
      guard let entry = keys.entry(for: key), entry.route == .settingsFile else {
        outcome.skipped.append(SkippedSetting(key: key, reason: notAccepted(key)))
        continue
      }
      guard let box = stored.box else {
        outcome.skipped.append(SkippedSetting(key: key, reason: .malformed))
        continue
      }
      await outcome.restore(entry, box, into: settings)
    }
    return outcome
  }

  /// The sealed map, written key by key through each key's own writer, like settings.
  ///
  /// The envelope proves the archive was sealed under a password the person typed; it says
  /// nothing about what is INSIDE, which is a map somebody else's software may have written.
  /// So it is held to what the exporter can produce (`sealedValues` in `ServerExporter`):
  ///
  ///   - only a key routed `.sealed`: a declared or field secret, or a portable confidential
  ///     value. Anything else is skipped: an unknown key would land under a name nothing
  ///     reads, and an ordinary setting written this way would go round `SettingPortability`;
  ///   - never empty. The exporter leaves an unset value out, so an empty one is a file
  ///     asking to CLEAR this server's password, which no export means;
  ///   - and through each key's own rules, so the value meets every rule a person setting
  ///     it would: a server password the password policy refuses is skipped, not stored.
  private func restoreSealed(_ values: [String: String]) async throws -> SectionOutcome {
    var outcome = SectionOutcome()
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
      guard let entry = keys.entry(for: key), entry.route == .sealed else {
        outcome.skipped.append(SkippedSetting(key: key, reason: notAccepted(key)))
        continue
      }
      guard !value.isEmpty else {
        outcome.skipped.append(SkippedSetting(key: key, reason: .malformed))
        continue
      }
      await outcome.restore(entry, .string(value), into: settings)
    }
    return outcome
  }

  /// Why a key this server does not take from this file was declined: it describes the
  /// server it came from, or it is not a key this file carries at all.
  private func notAccepted(_ key: String) -> SkippedSetting.Reason {
    SettingPortability.isPortable(key) ? .notExported : .describesAnotherServer
  }

  /// Inserts rows read generically, column by column as the archive names them.
  ///
  /// Columns the archive has and this schema does not are DROPPED rather than failing the
  /// import: an export from a newer server carrying an extra column should restore what it
  /// can, because the alternative is refusing a file whose every other row is fine.
  ///
  /// Only a ROWID alias is left for the database to assign. A contact's `id` is its
  /// identity (`TEXT PRIMARY KEY`, which every address row refers to), and dropping every
  /// column named `id` made every contact insert fail its NOT NULL.
  private static func insert(_ rows: [ExportedRow], into table: String, db: Database) throws {
    guard !rows.isEmpty, try db.tableExists(table) else { return }
    let rowIDAlias = try db.primaryKey(table).rowIDColumn
    let known = Set(try db.columns(in: table).map(\.name))
    for row in rows {
      let usable = row.values.filter { known.contains($0.key) && $0.key != rowIDAlias }
      guard !usable.isEmpty else { continue }
      let columns = usable.keys.sorted()
      let placeholders = SQLPlaceholders.list(columns.count)
      try db.execute(
        sql: """
          INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
          """,
        arguments: StatementArguments(columns.map { usable[$0]?.databaseValue ?? .null })
      )
    }
  }

  /// How many records a section's JSON holds, for a preview.
  ///
  /// Shape-tolerant on purpose: most sections are an array, settings is an object, and
  /// access control is an object of arrays. A count is a courtesy — being unable to work
  /// one out must not stop an import.
  static func count(in data: Data, for section: ExportSection) -> Int {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return 0 }
    if let array = object as? [Any] { return array.count }
    if let dictionary = object as? [String: Any] {
      // A contact's addresses travel beside it, and are not more contacts.
      if section == .contacts {
        return (dictionary[ExportedRow.contactTables[0]] as? [Any])?.count ?? 0
      }
      let nested = dictionary.values.compactMap { $0 as? [Any] }
      return nested.isEmpty ? dictionary.count : nested.reduce(0) { $0 + $1.count }
    }
    return 0
  }
}
