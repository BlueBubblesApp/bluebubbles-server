//  TLSKeychainRefusalTests
//  A Keychain that refuses to answer must never cost the user their certificate.
//
//  The two states this separates look identical through `try?` and are not remotely the same:
//
//    - ABSENT: nothing is stored. On a new Mac that is expected, because Keychain items are
//      `AfterFirstUnlockThisDeviceOnly` and do not travel in a backup or through Migration
//      Assistant. Generating a self-signed replacement and saying so is correct here.
//    - REFUSED: something is stored and the Keychain would not hand it over, which is what a
//      locked login keychain, a lost entitlement or a re-signed binary produces.
//
//  Collapsing the second into the first meant the imported branch generated a self-signed
//  certificate and PERSISTED it over `tls.certificate` and `tls.private_key`. The user's
//  certificate is then gone, and nothing in the server can get it back. That is a direct
//  breach of this file's own first rule: a user-supplied certificate is never regenerated or
//  deleted.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBPersistence
import BBServiceKit
import BBSettings
import BBSystem
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("TLS keychain refusal")
struct TLSKeychainRefusalTests {

  /// A store whose reads fail the way a locked Keychain's do, while still holding the values.
  private final class RefusingSecretStore: SecretStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var items: [String: String]
    /// Reads throw while this is true; the values stay where they are.
    var refusing: Bool
    private(set) var writes: [String] = []

    init(items: [String: String], refusing: Bool) {
      self.items = items
      self.refusing = refusing
    }

    func get(_ key: String) throws -> String? {
      if refusing { throw Refused() }
      return lock.withLock { items[key] }
    }

    func set(_ key: String, value: String) throws {
      lock.withLock {
        items[key] = value
        writes.append(key)
      }
    }

    func delete(_ key: String) throws {
      lock.withLock { _ = items.removeValue(forKey: key) }
    }

    func value(_ key: String) -> String? { lock.withLock { items[key] } }
    var writtenKeys: [String] { lock.withLock { writes } }
  }

  private static let certificate =
    "-----BEGIN CERTIFICATE-----\nIMPORTED\n-----END CERTIFICATE-----"
  private static let privateKey =
    "-----BEGIN PRIVATE KEY-----\nIMPORTED\n-----END PRIVATE KEY-----"

  private func refusingStore() -> RefusingSecretStore {
    RefusingSecretStore(
      items: [
        CertificateKeychainStore.certificateKey: Self.certificate,
        CertificateKeychainStore.privateKeyKey: Self.privateKey,
      ],
      refusing: true
    )
  }

  @Test("A refused read does not overwrite the stored certificate")
  func refusedReadKeepsTheCertificate() async throws {
    let secrets = refusingStore()
    let keychain = CertificateKeychainStore(secrets: secrets)
    let settings = try await Self.settings(origin: "imported")

    let material = await TLSProvisioning.material(
      settings: settings,
      store: Self.emptyStore(),
      keychain: keychain,
      alerts: nil,
      logger: Logger(label: "test")
    )

    // Plain HTTP for this run, which is the safe answer: the alternative is generating over
    // material that is very probably still there and merely unreadable right now.
    #expect(material == nil)

    // The whole point. Nothing was written, and both halves are exactly as they were.
    #expect(secrets.writtenKeys.isEmpty, "a refused read must not write anything")
    #expect(secrets.value(CertificateKeychainStore.certificateKey) == Self.certificate)
    #expect(secrets.value(CertificateKeychainStore.privateKeyKey) == Self.privateKey)
  }

  @Test("Once the Keychain answers again, the same certificate is served")
  func recoversWhenTheKeychainUnlocks() async throws {
    let secrets = refusingStore()
    let keychain = CertificateKeychainStore(secrets: secrets)
    let settings = try await Self.settings(origin: "imported")
    let store = Self.emptyStore()

    _ = await TLSProvisioning.material(
      settings: settings, store: store, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    // The user unlocks the login keychain and restarts the server.
    secrets.refusing = false
    let material = await TLSProvisioning.material(
      settings: settings, store: store, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    #expect(material?.certificatePEM == Self.certificate)
    #expect(material?.privateKeyPEM == Self.privateKey)
  }

  @Test("A genuinely empty Keychain still generates, as it must")
  func absentStillGenerates() async throws {
    // The other half of the distinction. On a new Mac there is nothing to protect, and
    // refusing to generate would leave HTTPS broken with no way forward.
    let secrets = RefusingSecretStore(items: [:], refusing: false)
    let keychain = CertificateKeychainStore(secrets: secrets)
    let settings = try await Self.settings(origin: "imported")

    let material = await TLSProvisioning.material(
      settings: settings,
      store: Self.emptyStore(),
      keychain: keychain,
      alerts: nil,
      logger: Logger(label: "test")
    )

    #expect(material != nil, "an empty keychain should produce a self-signed certificate")
    #expect(secrets.value(CertificateKeychainStore.certificateKey)?.isEmpty == false)
  }

  // MARK: - Fixtures

  private static func emptyStore() -> CertificateStore {
    CertificateStore(
      directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bb-tls-refusal-\(UUID().uuidString)", isDirectory: true))
  }

  private static func settings(origin: String) async throws -> ScopedSettings {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(database: database, secrets: InMemorySecretStore())
    try await store.set(Settings.useCustomCertificate, to: true)
    try await store.set(Settings.tlsCertificateOrigin, to: origin)
    return ScopedSettings(
      store: store, manifest: BuiltInManifests.http, secretKeys: Settings.secretKeys)
  }
}
