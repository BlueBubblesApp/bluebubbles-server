//  CredentialVault
//  The credentials an archive carries that are not settings: the Firebase documents and the
//  TLS certificate, each in Keychain items of its own.
//
//  **A protocol, because the stores are above this module.** `PushCredentialStore` is in
//  BBPushKit and `CertificateKeychainStore` in the composition root, and what a restore has
//  to do around them (clearing devices on a Firebase project change, recording where a
//  certificate came from) lives with them. The composition implements this and `Storage`
//  hands it to the exporter and the importer it builds, for the app and the CLI alike.
//
//  **The vault validates; this module seals and reports.** A document is held to the same
//  parse the in-app import uses, and a certificate to its key and its expiry, BEFORE anything
//  is written, so a forged or damaged archive changes nothing. What the vault answers is in
//  this module's terms, `CredentialRestore`, so the importer reports a refusal or a failed
//  write the way it reports a setting's.
//
//  **Only a certificate the person supplied is exported.** A certificate this server
//  generated names the machine that generated it (its Bonjour name, the address it
//  published then) and is replaced for free wherever `use_custom_certificate` is on and none
//  is stored. Carrying it would copy a private key to a second machine to present names that
//  are wrong there. One the person supplied is the opposite: a certificate somebody paid for,
//  or set their DNS up around, which nothing can regenerate. `CertificateExport` keeps the
//  two apart so the exporter can say which it found.

import Foundation

/// The Firebase documents exactly as they were imported, which is how they are stored.
///
/// Text rather than a parsed model, for the reason `PushCredentialStore` keeps them that
/// way: the client configuration is served to clients whole, and a projection drops the
/// fields they read.
public struct FirebaseCredentials: Codable, Sendable, Equatable {
  /// The service account key (`server.json`), or nil when none is stored.
  public let serviceAccount: String?
  /// The client configuration (`google-services.json`), or nil when none is stored.
  public let clientConfig: String?

  public init(serviceAccount: String?, clientConfig: String?) {
    self.serviceAccount = serviceAccount
    self.clientConfig = clientConfig
  }

  /// How many of the two documents are present and non-empty.
  public var documentCount: Int {
    [serviceAccount, clientConfig].count(where: { $0?.isEmpty == false })
  }
}

/// A TLS certificate and its key, as PEM text.
public struct CertificateCredentials: Codable, Sendable, Equatable {
  /// The certificate, followed by any chain, as stored.
  public let certificatePEM: String
  public let privateKeyPEM: String

  public init(certificatePEM: String, privateKeyPEM: String) {
    self.certificatePEM = certificatePEM
    self.privateKeyPEM = privateKeyPEM
  }
}

/// What a server holds as its TLS certificate, as far as an export is concerned.
public enum CertificateExport: Sendable, Equatable {
  /// Nothing is stored.
  case absent
  /// The server generated it. Not exported; see the header.
  case generatedByThisServer
  /// The person supplied it.
  case supplied(CertificateCredentials)
}

/// One thing a credential section restores, named the way an import report names it.
public enum CredentialDocument: String, Sendable, CaseIterable {
  case firebaseServiceAccount = "firebaseCredentials.serviceAccount"
  case firebaseClientConfig = "firebaseCredentials.clientConfig"
  case tlsCertificate = "tlsCertificate"
}

/// What restoring one credential section did.
public struct CredentialRestore: Sendable, Equatable {
  /// What was stored.
  public var stored: [CredentialDocument] = []
  /// What was refused before anything was written, with the sentence saying why.
  public var refused: [Refusal] = []
  /// What was accepted and could not be stored, through `DiagnosticText`.
  public var failed: [Refusal] = []

  public struct Refusal: Sendable, Equatable {
    public let document: CredentialDocument
    public let sentence: String

    public init(_ document: CredentialDocument, _ sentence: String) {
      self.document = document
      self.sentence = sentence
    }
  }

  public init(
    stored: [CredentialDocument] = [], refused: [Refusal] = [], failed: [Refusal] = []
  ) {
    self.stored = stored
    self.refused = refused
    self.failed = failed
  }
}

/// Reads and restores the credentials that live outside settings. See the header.
public protocol CredentialVault: Sendable {
  /// The stored Firebase documents, or nil when neither is stored.
  func firebaseCredentials() async throws -> FirebaseCredentials?

  /// The stored TLS certificate, and whether the person supplied it.
  func tlsCertificate() async throws -> CertificateExport

  /// Validates every document present and, only when all of them pass, stores them.
  ///
  /// - Parameter keepingDevices: whether the same import restored the registered devices.
  ///   Credentials for a different Firebase project make the devices registered here
  ///   unreachable, so they are removed, as the in-app import removes them; devices that
  ///   came from the same archive belong to the incoming project and are kept.
  func restore(_ credentials: FirebaseCredentials, keepingDevices: Bool) async
    -> CredentialRestore

  /// Validates the certificate against its key and its expiry and, only when it passes,
  /// stores it as one the person supplied.
  func restore(_ certificate: CertificateCredentials) async -> CredentialRestore
}
