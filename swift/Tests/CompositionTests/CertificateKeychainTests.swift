//  CertificateKeychainTests
//  Moving TLS material into the Keychain, and the two properties that must not invert.
//
//  **The files ARE deleted, and the order is the safety argument.** `install` verifies by
//  reading back and throws otherwise, so `Certs/` is cleared only once the Keychain definitely
//  holds the material; a failure leaves the files exactly where they were and the step
//  retryable. Keeping them as a live second copy was the earlier design and it bought nothing:
//  an unsigned build cannot read what a signed one wrote in any case, because the two are
//  talking to different keychains.
//
//  **Provenance fails safe toward "the user installed this".** The rule used to be encoded by
//  the ABSENCE of `Certs/expiration.txt`, which only this server writes: no marker meant no
//  regeneration. That is unreadable and cannot survive the move to a store with no files, so
//  it is an explicit setting now — and the mapping has to keep the same direction. Getting it
//  backwards means silently replacing a certificate somebody paid for.

import BBCore
import BBPersistence
import BBSettings
import BBSystem
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Certificates in the Keychain")
struct CertificateKeychainTests {

  private func makeStore(_ secrets: InMemorySecretStore) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    return try await SettingsStore(database: database, secrets: secrets)
  }

  private func diskStore() -> CertificateStore {
    CertificateStore(
      directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bb-certs-\(UUID().uuidString)"))
  }

  /// Real generated material, never a fixture — the same choice `CertificateStoreTests` makes.
  private func material() throws -> CertificateStore.Material {
    let generated = try CertificateAuthority.selfSigned(hostnames: ["localhost"])
    return CertificateStore.Material(
      certificatePEM: generated.certificatePEM, privateKeyPEM: generated.privateKeyPEM)
  }

  @Test("Material round-trips through the Keychain")
  func roundTrip() async throws {
    let secrets = InMemorySecretStore()
    let keychain = CertificateKeychainStore(secrets: secrets)
    let original = try material()

    #expect(await keychain.exists() == false)
    try await keychain.install(original)
    #expect(await keychain.exists())
    #expect(try await keychain.load() == original)

    await keychain.clear()
    #expect(await keychain.exists() == false)
  }

  /// Half a pair cannot bind, and reporting it as present sends the caller down the load path
  /// to fail there instead.
  @Test("A certificate without its key does not count as installed")
  func halfAPairIsNotInstalled() async throws {
    let secrets = InMemorySecretStore()
    try secrets.set(CertificateKeychainStore.certificateKey, value: try material().certificatePEM)

    let keychain = CertificateKeychainStore(secrets: secrets)
    #expect(await keychain.exists() == false)
    #expect(try await keychain.load() == nil)
  }

  @Test("Migrating moves into the Keychain and removes the files")
  func migrationMovesRatherThanCopies() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-cert-mig-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let disk = CertificateStore(directory: base.appendingPathComponent("Certs"))
    let original = try material()
    try disk.install(original)

    let secrets = InMemorySecretStore()
    let settings = try await makeStore(secrets)

    let report = await MigrationRunner.run(
      .certificates, settings: settings, secrets: secrets,
      logger: Logger(label: "test"), base: base)
    #expect(report.state == .completed)

    // In the Keychain…
    #expect(try await CertificateKeychainStore(secrets: secrets).load() == original)
    // …and gone from disk. A second copy nothing keeps current is a stale certificate waiting
    // for the day something reads it.
    #expect(disk.exists == false)
  }

  /// The direction that matters. No expiry marker meant "the user installed this", and the
  /// recorded origin has to say the same thing.
  @Test("A certificate with no expiry marker is recorded as the user's own")
  func absentMarkerMeansImported() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-cert-imp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let disk = CertificateStore(directory: base.appendingPathComponent("Certs"))
    try disk.install(try material())
    // No `recordExpiration` — which is what `CertificateImportView` produces.

    let secrets = InMemorySecretStore()
    let settings = try await makeStore(secrets)
    _ = await MigrationRunner.run(
      .certificates, settings: settings, secrets: secrets,
      logger: Logger(label: "test"), base: base)

    #expect(
      await settings.get(Settings.tlsCertificateOrigin) == TLSCertificateOrigin.imported.rawValue)
    #expect(await settings.get(Settings.tlsCertificateExpiresAt) == 0)
  }

  @Test("A certificate this server generated is recorded as self-signed, with its expiry")
  func markerMeansSelfSigned() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-cert-gen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let disk = CertificateStore(directory: base.appendingPathComponent("Certs"))
    try disk.install(try material())
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    try disk.recordExpiration(expiry)

    let secrets = InMemorySecretStore()
    let settings = try await makeStore(secrets)
    _ = await MigrationRunner.run(
      .certificates, settings: settings, secrets: secrets,
      logger: Logger(label: "test"), base: base)

    #expect(
      await settings.get(Settings.tlsCertificateOrigin) == TLSCertificateOrigin.selfSigned.rawValue)
    #expect(await settings.get(Settings.tlsCertificateExpiresAt) == 2_000_000_000)
  }

  /// Unknown must not read as "ours to replace". A typo, a partial write or a value written by
  /// an older build all land here, and all of them must leave the certificate alone.
  @Test("An unrecognised origin is treated as the user's own")
  func unknownOriginIsImported() {
    #expect(TLSCertificateOrigin(rawValue: "") == .imported)
    #expect(TLSCertificateOrigin(rawValue: "nonsense") == .imported)
    #expect(TLSCertificateOrigin(rawValue: "SELF-SIGNED") == .imported, "matching is exact")
    #expect(TLSCertificateOrigin(rawValue: "self-signed") == .selfSigned)
  }

  /// What `CertificateImportView.install` writes, asserted without the view.
  ///
  /// The view itself is not testable here — it needs a running server for the settings store
  /// — but the CONTRACT it has to honour is, and getting it wrong is expensive: an imported
  /// certificate recorded as self-signed is one the renewer will eventually replace.
  ///
  /// Expiry is deliberately zero rather than the certificate's real notAfter. This field is
  /// the renewal clock, not a display value, and a real date here would invite the renewer to
  /// act on a certificate that is not ours.
  @Test("An imported certificate is recorded as the user's own, with no renewal date")
  func importContract() async throws {
    let secrets = InMemorySecretStore()
    let settings = try await makeStore(secrets)
    let keychain = CertificateKeychainStore(secrets: secrets)
    let imported = try material()

    try await keychain.install(imported)
    try await settings.write { batch in
      try batch.set(Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.imported.rawValue)
      try batch.set(Settings.tlsCertificateExpiresAt, to: 0)
    }

    #expect(try await keychain.load() == imported)
    let origin = TLSCertificateOrigin(
      rawValue: await settings.get(Settings.tlsCertificateOrigin))
    #expect(origin == .imported)
    #expect(await settings.get(Settings.tlsCertificateExpiresAt) == 0)
  }

  @Test("Nothing on disk is not a failure")
  func nothingToMigrate() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-cert-none-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let secrets = InMemorySecretStore()
    let settings = try await makeStore(secrets)
    let report = await MigrationRunner.run(
      .certificates, settings: settings, secrets: secrets,
      logger: Logger(label: "test"), base: base)

    #expect(report.state == .completed)
    #expect(report.detail == "no certificate on disk")
  }
}
