//  CredentialExportTests
//  The Firebase credentials and the TLS certificate, out of one server and into another.
//
//  Both live in Keychain items outside settings, so neither travelled in an export until
//  they were sections of their own. What these hold the two sections to:
//
//    - they are sealed under the server password, like the secrets, and refused without it;
//    - a restore validates before it writes, so a forged or damaged section changes
//      nothing and says which document and why;
//    - a restore has the in-app import's effects: devices registered against a different
//      Firebase project go, and a certificate is recorded as the person's own;
//    - only a certificate the person supplied is exported, never one this server made.
//
//  Every Keychain here is in memory and every certificate directory is temporary.
//
//  NO REAL ADDRESSES OR CREDENTIALS; see CONTRIBUTING.md.

import BBAppStore
import BBBuiltIns
import BBCore
import BBPersistence
import BBPushKit
import BBSettings
import BBSystem
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BBExport
@testable import BlueBubblesServerCore

@Suite("Credential export", .serialized)
struct CredentialExportTests {

  private let logger = Logger(label: "bluebubbles.test.credentials")
  private static let password = "a-long-enough-passphrase-42"

  /// One server: its database, settings, Keychain, a temporary `Certs/` and the vault over
  /// them.
  private struct Server {
    let database: AppDatabase
    let settings: SettingsStore
    let secrets: InMemorySecretStore
    let legacyCertificates: CertificateStore
    let vault: KeychainCredentialVault

    var push: PushCredentialStore { PushCredentialStore(secrets: secrets) }
    var certificates: CertificateKeychainStore { CertificateKeychainStore(secrets: secrets) }
  }

  private func server(root: URL) async throws -> Server {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let secrets = InMemorySecretStore()
    let settings = try await TestSettings.store(database: database, secrets: secrets)
    let legacy = CertificateStore(
      directory: root.appendingPathComponent("Certs-\(UUID().uuidString)", isDirectory: true))
    return Server(
      database: database, settings: settings, secrets: secrets, legacyCertificates: legacy,
      vault: KeychainCredentialVault(
        secrets: secrets, settings: settings, database: database,
        legacyCertificates: legacy, logger: logger))
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-credential-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func exporter(_ server: Server) -> ServerExporter {
    ServerExporter(
      database: server.database, settings: server.settings, services: BuiltInManifests.all,
      credentials: server.vault, serverVersion: "test", logger: logger)
  }

  private func importer(_ server: Server) -> ServerImporter {
    ServerImporter(
      database: server.database, settings: server.settings, services: BuiltInManifests.all,
      credentials: server.vault, logger: logger)
  }

  /// A server with a password, Firebase set up, and a certificate the person supplied.
  private func configuredSource(root: URL) async throws -> (Server, GeneratedCertificate) {
    let source = try await server(root: root)
    try await source.settings.set(Settings.password, to: Self.password)
    try await source.push.importServiceAccount(Data(MigrationStateTests.serviceAccountJSON.utf8))
    try await source.push.importClientConfig(Data(MigrationStateTests.clientConfigJSON.utf8))
    let supplied = try CertificateAuthority.selfSigned(hostnames: ["bluebubbles.example.com"])
    try await source.certificates.install(
      CertificateStore.Material(
        certificatePEM: supplied.certificatePEM, privateKeyPEM: supplied.privateKeyPEM))
    try await source.settings.set(
      Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.imported.rawValue)
    return (source, supplied)
  }

  /// Replaces a sealed section's contents with `payload`, sealed under the same password, as
  /// somebody holding the password could.
  private func reseal<Payload: Encodable>(
    _ payload: Payload, as section: ExportSection, in inspection: ServerImporter.Inspection
  ) throws {
    let envelope = try SecretsEnvelope.seal(
      try JSONEncoder().encode(payload), withServerPassword: Self.password)
    try JSONEncoder().encode(envelope)
      .write(to: inspection.directory.appendingPathComponent(section.fileName))
  }

  // MARK: Round trips

  @Test("Firebase credentials travel sealed and come back byte for byte")
  func firebaseRoundTrip() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)

    let report = try await exporter(source).export(
      sections: [.firebaseCredentials], to: root, serverPassword: Self.password)
    #expect(report.counts[.firebaseCredentials] == 2)
    let raw = try Data(contentsOf: report.url)
    #expect(
      raw.range(of: Data("not-a-real-key".utf8)) == nil,
      "the service account's private key is in the archive in the clear")

    let target = try await server(root: root)
    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(inspection.hasSealedSections)
    let applied = try await importer.apply(
      inspection, sections: [.firebaseCredentials], serverPassword: Self.password)

    #expect(applied.counts[.firebaseCredentials] == 2)
    #expect(applied.skippedSettings.isEmpty && applied.failedSettings.isEmpty)
    #expect(try await target.push.rawServiceAccount() == source.push.rawServiceAccount())
    #expect(try await target.push.rawClientConfig() == source.push.rawClientConfig())
  }

  @Test("A supplied certificate travels sealed, and lands as the person's own")
  func certificateRoundTrip() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, supplied) = try await configuredSource(root: root)

    let report = try await exporter(source).export(
      sections: [.tlsCertificate], to: root, serverPassword: Self.password)
    let raw = try Data(contentsOf: report.url)
    #expect(
      raw.range(of: Data("PRIVATE KEY".utf8)) == nil,
      "the TLS private key is in the archive in the clear")

    // The target has an old certificate an earlier build left on disk, and a generated one
    // recorded with a renewal clock; the restore replaces both facts.
    let target = try await server(root: root)
    let stale = try CertificateAuthority.selfSigned()
    try target.legacyCertificates.install(
      CertificateStore.Material(
        certificatePEM: stale.certificatePEM, privateKeyPEM: stale.privateKeyPEM))
    try await target.settings.set(
      Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.selfSigned.rawValue)
    try await target.settings.set(Settings.tlsCertificateExpiresAt, to: 1_900_000_000)

    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    let applied = try await importer.apply(
      inspection, sections: [.tlsCertificate], serverPassword: Self.password)

    #expect(applied.counts[.tlsCertificate] == 1)
    let stored = try #require(try await target.certificates.load())
    #expect(stored.certificatePEM == supplied.certificatePEM)
    #expect(stored.privateKeyPEM == supplied.privateKeyPEM)
    #expect(
      await target.settings.get(Settings.tlsCertificateOrigin)
        == TLSCertificateOrigin.imported.rawValue,
      "a restored certificate the renewer thinks is its own would be replaced on a restart")
    #expect(await target.settings.get(Settings.tlsCertificateExpiresAt) == 0)
    #expect(!target.legacyCertificates.exists, "a stale certificate was left to be adopted")
  }

  // MARK: The password

  @Test("Neither section is exported without this server's password")
  func exportNeedsThePassword() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    for section: ExportSection in [.firebaseCredentials, .tlsCertificate] {
      await #expect(throws: SecretsEnvelope.Failure.wrongPassword) {
        _ = try await exporter(source).export(
          sections: [section], to: root, serverPassword: "something-else-entirely-99")
      }
    }

    let unprotected = try await server(root: root)
    try await unprotected.push.importServiceAccount(
      Data(MigrationStateTests.serviceAccountJSON.utf8))
    await #expect(throws: SecretsEnvelope.Failure.noServerPassword) {
      _ = try await exporter(unprotected).export(
        sections: [.firebaseCredentials], to: root, serverPassword: "")
    }
  }

  @Test("Importing either section without a password is refused before anything is written")
  func importNeedsThePassword() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    let report = try await exporter(source).export(
      sections: [.firebaseCredentials, .tlsCertificate], to: root,
      serverPassword: Self.password)

    let target = try await server(root: root)
    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    for section: ExportSection in [.firebaseCredentials, .tlsCertificate] {
      await #expect(throws: ServerImporter.Failure.passwordRequired) {
        _ = try await importer.apply(inspection, sections: [section])
      }
    }
    #expect(try await target.push.rawServiceAccount() == nil)
    #expect(try await target.certificates.load() == nil)
  }

  /// The sealed sections come last. Opened as the loop reached them, a mistyped password
  /// was found after the settings had already been replaced.
  @Test("A wrong password is found before any section is written")
  func wrongPasswordWritesNothing() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    try await source.settings.set(Settings.socketPort, to: 8080)
    let report = try await exporter(source).export(
      sections: [.settings, .firebaseCredentials], to: root, serverPassword: Self.password)

    let target = try await server(root: root)
    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    await #expect(throws: SecretsEnvelope.Failure.wrongPasswordOrDamaged) {
      _ = try await importer.apply(
        inspection, sections: [.settings, .firebaseCredentials],
        serverPassword: "not-the-right-one")
    }
    #expect(await target.settings.get(Settings.socketPort) != 8080)
    #expect(try await target.push.rawServiceAccount() == nil)
  }

  // MARK: Refusals

  /// The envelope proves who sealed it, not what is inside. A section holding a document
  /// the in-app import would refuse is refused the same way, and its valid partner is not
  /// written beside it.
  @Test("A forged Firebase section is refused, and nothing in it is written")
  func forgedFirebaseIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    let report = try await exporter(source).export(
      sections: [.firebaseCredentials], to: root, serverPassword: Self.password)

    let target = try await server(root: root)
    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    try reseal(
      FirebaseCredentials(
        serviceAccount: #"{"type": "authorized_user", "client_id": "x"}"#,
        clientConfig: MigrationStateTests.clientConfigJSON),
      as: .firebaseCredentials, in: inspection)

    let applied = try await importer.apply(
      inspection, sections: [.firebaseCredentials], serverPassword: Self.password)
    #expect(applied.counts[.firebaseCredentials] == 0)
    #expect(
      applied.skippedSettings.map(\.key) == [CredentialDocument.firebaseServiceAccount.rawValue])
    #expect(applied.skippedSettings.allSatisfy { !$0.explanation.isEmpty })
    #expect(try await target.push.rawServiceAccount() == nil)
    #expect(
      try await target.push.rawClientConfig() == nil,
      "the valid half was written beside a refused one")
  }

  @Test("A section asking to clear the credentials is refused, not obeyed")
  func emptyFirebaseIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    let report = try await exporter(source).export(
      sections: [.firebaseCredentials], to: root, serverPassword: Self.password)

    let (target, _) = try await configuredSource(root: root)
    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    try reseal(
      FirebaseCredentials(serviceAccount: "", clientConfig: nil),
      as: .firebaseCredentials, in: inspection)

    let applied = try await importer.apply(
      inspection, sections: [.firebaseCredentials], serverPassword: Self.password)
    #expect(applied.skippedSettings.map(\.key) == [ExportSection.firebaseCredentials.rawValue])
    #expect(try await target.push.rawServiceAccount() != nil)
  }

  @Test("A certificate whose key is not its own, or which has expired, is refused")
  func invalidCertificateIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    let report = try await exporter(source).export(
      sections: [.tlsCertificate], to: root, serverPassword: Self.password)

    let one = try CertificateAuthority.selfSigned()
    let other = try CertificateAuthority.selfSigned()
    let expired = try CertificateAuthority.selfSigned(
      now: Date().addingTimeInterval(-2 * CertificateAuthority.validity))
    let forgeries = [
      CertificateCredentials(
        certificatePEM: one.certificatePEM, privateKeyPEM: other.privateKeyPEM),
      CertificateCredentials(
        certificatePEM: expired.certificatePEM, privateKeyPEM: expired.privateKeyPEM),
      CertificateCredentials(certificatePEM: "not a certificate", privateKeyPEM: one.privateKeyPEM),
    ]
    for forgery in forgeries {
      let target = try await server(root: root)
      let importer = importer(target)
      let inspection = try await importer.inspect(report.url)
      defer { try? FileManager.default.removeItem(at: inspection.directory) }
      try reseal(forgery, as: .tlsCertificate, in: inspection)

      let applied = try await importer.apply(
        inspection, sections: [.tlsCertificate], serverPassword: Self.password)
      #expect(applied.skippedSettings.map(\.key) == [CredentialDocument.tlsCertificate.rawValue])
      #expect(try await target.certificates.load() == nil)
      #expect(await target.settings.get(Settings.tlsCertificateOrigin).isEmpty)
    }
  }

  // MARK: What is exported

  /// A generated certificate names the machine that made it, and the target makes its own
  /// for free; refusing says so, where an empty section would read as a backup.
  @Test("A certificate this server generated is not exported, and the refusal says why")
  func generatedCertificateIsNotExported() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    try await source.settings.set(
      Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.selfSigned.rawValue)
    await #expect(throws: ServerExporter.Failure.certificateGeneratedHere) {
      _ = try await exporter(source).export(
        sections: [.tlsCertificate], to: root, serverPassword: Self.password)
    }
  }

  @Test("A ticked credential section with nothing to carry is refused, not written empty")
  func nothingToExportIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = try await server(root: root)
    try await empty.settings.set(Settings.password, to: Self.password)
    for section: ExportSection in [.firebaseCredentials, .tlsCertificate] {
      await #expect(throws: ServerExporter.Failure.nothingToExport(section)) {
        _ = try await exporter(empty).export(
          sections: [section], to: root, serverPassword: Self.password)
      }
    }
  }

  // MARK: The in-app import's effects

  /// Tokens are minted by one Firebase project and mean nothing to another, so credentials
  /// for a different project take the registered devices with them, as the in-app import
  /// does. Devices restored from the same archive belong to the incoming project and stay.
  @Test("A different project clears the devices, unless they came in the same archive")
  func projectChangeClearsDevices() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    try await DeviceRepository(database: source.database, logger: logger)
      .register(name: "From the archive", identifier: "token-archive")
    let report = try await exporter(source).export(
      sections: [.devices, .firebaseCredentials], to: root, serverPassword: Self.password)

    for restoringDevices in [false, true] {
      let target = try await server(root: root)
      let otherProject = MigrationStateTests.serviceAccountJSON
        .replacingOccurrences(of: "bluebubbles-test", with: "another-project")
      try await target.push.importServiceAccount(Data(otherProject.utf8))
      let devices = DeviceRepository(database: target.database, logger: logger)
      try await devices.register(name: "Registered here", identifier: "token-here")

      let importer = importer(target)
      let inspection = try await importer.inspect(report.url)
      defer { try? FileManager.default.removeItem(at: inspection.directory) }
      _ = try await importer.apply(
        inspection,
        sections: restoringDevices ? [.devices, .firebaseCredentials] : [.firebaseCredentials],
        serverPassword: Self.password)

      #expect(
        try await devices.all().map(\.identifier) == (restoringDevices ? ["token-archive"] : []),
        "restoring devices: \(restoringDevices)")
      #expect(await target.push.currentProjectId() == "bluebubbles-test")
    }
  }

  // MARK: Archives either side of these sections

  @Test("An archive made before these sections existed still imports")
  func olderArchiveImports() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, _) = try await configuredSource(root: root)
    try await source.settings.set(Settings.socketPort, to: 8080)
    let report = try await exporter(source).export(
      sections: [.settings, .secrets], to: root, serverPassword: Self.password)

    // As the older format wrote it: the manifest names only the sections it had.
    let target = try await server(root: root)
    let importer = importer(target)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    let manifest = try JSONSerialization.jsonObject(
      with: try Data(contentsOf: inspection.directory.appendingPathComponent("export.json")))
    #expect((manifest as? [String: Any])?["sections"] as? [String] == ["settings", "secrets"])

    _ = try await importer.apply(
      inspection, sections: Set(inspection.sections), serverPassword: Self.password)
    #expect(await target.settings.get(Settings.socketPort) == 8080)
    #expect(try await target.push.rawServiceAccount() == nil)
  }

  /// An archive from a newer version naming a section this one does not know is refused
  /// by name before anything is read, rather than failing to decode with a sentence about
  /// JSON, or importing the rest and dropping what it could not read.
  @Test("A section this version does not know is refused by name")
  func unknownSectionIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await server(root: root)
    let report = try await exporter(source).export(sections: [.settings], to: root)

    let importer = importer(source)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    let manifestURL = inspection.directory.appendingPathComponent("export.json")
    var manifest = try #require(
      try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
        as? [String: Any])
    manifest["sections"] = ["settings", "somethingNewer"]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let future = root.appendingPathComponent("future.zip")
    try await ZipArchive.create(contentsOf: inspection.directory, into: future)

    await #expect(throws: ExportManifest.Failure.unrecognisedSections(["somethingNewer"])) {
      _ = try await importer.inspect(future)
    }
  }

  // MARK: Wiring

  /// The vault is only as good as the hand-over: an exporter or importer a front end builds
  /// without it refuses both sections, so the person would be told, but could not use them.
  @Test("Storage's exporter and importer are handed the vault")
  func vaultIsWired() throws {
    let operations = try SourceScanner.file(
      "Sources/BlueBubblesServerCore/Composition/StorageOperations.swift"
    ).text
    #expect(
      operations.components(separatedBy: "credentials: credentialVault").count - 1 == 2,
      "the exporter and the importer must both be given the vault")
  }
}
