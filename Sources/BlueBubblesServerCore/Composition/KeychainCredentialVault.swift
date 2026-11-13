//  KeychainCredentialVault
//  The Firebase documents and the TLS certificate, read for an export and restored from one,
//  through the stores that own them.
//
//  **Every write goes through the path the in-app import takes, so a restore has the same
//  effect.** Firebase documents are parsed and stored by `PushCredentialStore`'s own import
//  methods; a project change clears the registered devices through `DeviceDirectory`, as
//  `PushInterface.import` does; and the push service is restarted when the importer
//  announces the section (`LiveRestoreTarget`), through the lifecycle the in-app import
//  restarts it through. A certificate goes through `ImportedCertificate`, the Security
//  page's own sequence. A second path would be one more place for the effects to drift.
//
//  **Validated in full before anything is written.** Both Firebase documents are parsed
//  before either is stored: credentials for one project beside a configuration that failed
//  to parse would leave push half set up, which `PushStatus` exists to warn about. A
//  forged or damaged section therefore changes nothing, and says which document and why.
//
//  Which certificate is exported, and why only one the person supplied, is
//  `CredentialVault`'s header.

import BBAppStore
import BBCore
import BBExport
import BBInterfaces
import BBPersistence
import BBPushKit
import BBSettings
import BBSystem
import Foundation
import Logging

struct KeychainCredentialVault: CredentialVault {

  let secrets: any SecretStore
  let settings: SettingsStore
  let database: AppDatabase
  /// Where an older build left TLS files, cleared once a certificate is installed. The
  /// real one in production; a test passes a temporary directory.
  let legacyCertificates: CertificateStore
  let logger: Logger

  private var push: PushCredentialStore { PushCredentialStore(secrets: secrets) }
  private var certificates: CertificateKeychainStore {
    CertificateKeychainStore(secrets: secrets, logger: logger)
  }

  // MARK: - Export

  func firebaseCredentials() async throws -> FirebaseCredentials? {
    let store = push
    let serviceAccount = try await store.rawServiceAccount()
    let clientConfig = try await store.rawClientConfig()
    guard serviceAccount != nil || clientConfig != nil else { return nil }
    return FirebaseCredentials(
      serviceAccount: serviceAccount.map { String(decoding: $0, as: UTF8.self) },
      clientConfig: clientConfig.map { String(decoding: $0, as: UTF8.self) })
  }

  func tlsCertificate() async throws -> CertificateExport {
    guard let material = try await certificates.load() else { return .absent }
    // The same reading the renewer makes: only a certificate recorded as self-signed is
    // this server's own, and an unknown origin is the user's.
    let origin = TLSCertificateOrigin(rawValue: await settings.get(Settings.tlsCertificateOrigin))
    guard origin == .imported else { return .generatedByThisServer }
    return .supplied(
      CertificateCredentials(
        certificatePEM: material.certificatePEM, privateKeyPEM: material.privateKeyPEM))
  }

  // MARK: - Restore

  func restore(_ credentials: FirebaseCredentials, keepingDevices: Bool) async
    -> CredentialRestore
  {
    let serviceAccount = credentials.serviceAccount.map { Data($0.utf8) }
    let clientConfig = credentials.clientConfig.map { Data($0.utf8) }

    // Both parsed before either is written; see the header. The same `parse` each import
    // method runs again, so what is checked here is what is stored.
    var outcome = CredentialRestore()
    var incomingProject: String?
    if let serviceAccount {
      do {
        incomingProject = try ServiceAccount.parse(serviceAccount).projectId
      } catch {
        outcome.refused.append(
          .init(.firebaseServiceAccount, DiagnosticText.sentence(for: error)))
      }
    }
    if let clientConfig {
      do {
        _ = try FirebaseClientConfig.parse(clientConfig)
      } catch {
        outcome.refused.append(.init(.firebaseClientConfig, DiagnosticText.sentence(for: error)))
      }
    }
    guard outcome.refused.isEmpty else { return outcome }

    let store = push
    // Before the credentials land, as `PushInterface.import` does, so a failure part-way
    // does not leave the new project's credentials beside the old project's devices.
    if !keepingDevices, let incomingProject,
      let current = await store.currentProjectId(), current != incomingProject
    {
      logger.info("A restore changed the Firebase project; clearing registered devices")
      await DeviceDirectory(repository: DeviceRepository(database: database, logger: logger))
        .removeAll()
    }

    if let serviceAccount {
      do {
        try await store.importServiceAccount(serviceAccount)
        outcome.stored.append(.firebaseServiceAccount)
      } catch {
        outcome.failed.append(.init(.firebaseServiceAccount, DiagnosticText.sentence(for: error)))
      }
    }
    if let clientConfig {
      do {
        try await store.importClientConfig(clientConfig)
        outcome.stored.append(.firebaseClientConfig)
      } catch {
        outcome.failed.append(.init(.firebaseClientConfig, DiagnosticText.sentence(for: error)))
      }
    }
    return outcome
  }

  func restore(_ certificate: CertificateCredentials) async -> CredentialRestore {
    let material = CertificateStore.Material(
      certificatePEM: certificate.certificatePEM, privateKeyPEM: certificate.privateKeyPEM)
    // Refused and failed are told apart here, before the shared install runs both: a
    // certificate this server cannot use is the archive's problem, a Keychain that will not
    // keep a good one is this server's.
    do {
      _ = try CertificateAuthority.validate(
        certificatePEM: material.certificatePEM, privateKeyPEM: material.privateKeyPEM)
    } catch {
      return CredentialRestore(refused: [
        .init(.tlsCertificate, DiagnosticText.sentence(for: error))
      ])
    }
    do {
      try await ImportedCertificate.install(
        material, keychain: certificates, legacyFiles: legacyCertificates)
      _ = try await settings.write(ImportedCertificate.provenance)
      return CredentialRestore(stored: [.tlsCertificate])
    } catch {
      return CredentialRestore(failed: [
        .init(.tlsCertificate, DiagnosticText.sentence(for: error))
      ])
    }
  }
}
