//  CertificateKeychainStore
//  TLS material in the Keychain rather than in two files.
//
//  What this is worth. `Certs/server.key` is `0600`, which stops another USER and does
//  nothing about another process running as you — the threat model that put every other
//  secret in the Keychain. A data protection Keychain item is refused outright to anything
//  outside the access group, and `AfterFirstUnlockThisDeviceOnly` keeps it out of a Time
//  Machine backup, which a `0600` file is not.
//
//  Why it lives here rather than beside `CertificateStore` in BBSystem: it needs
//  `SecretStore`, which is BBSettings, and BBSystem does not depend on BBSettings. The
//  composition root already depends on both, so this adds no package edge — the same reason
//  `Migration/` sits here.
//
//  **This is the only store.** `Certs/server.pem` and `server.key` are an adoption SOURCE, not
//  a second copy: `TLSProvisioning` reads them once when the Keychain is empty, installs them
//  here, and deletes them. Nothing writes them.
//
//  They were kept as a live fallback for one iteration, on the reasoning that an unsigned build
//  cannot reach the data protection keychain and would otherwise bind no TLS. That reasoning
//  does not survive contact with `SecretStore`: an unsigned build falls back to the LEGACY
//  keychain, which is a different store, so it could never read what a signed build wrote
//  regardless. What the files actually bought was a second source of truth to keep in step
//  forever — and the first thing that went wrong was exactly that, a renewal writing to one
//  and the reader consulting the other. An unsigned build now generates its own self-signed
//  certificate into its own keychain, which is both simpler and more honest about what it is.
//
//  `install` verifying by read-back is what makes deletion safe: it throws unless the material
//  is provably retrievable, so the files are removed only after something else holds them.
//
//  Provenance does NOT live here. Whether a certificate was generated or imported, and when
//  it expires, are settings rows — see `Settings.tlsCertificateOrigin`. They are not secret,
//  and a person debugging why their certificate was replaced needs to be able to read them.

import BBCore
import BBSettings
import BBSystem
import Foundation
import Logging

public actor CertificateKeychainStore {

  static let certificateKey = "tls.certificate"
  static let privateKeyKey = "tls.private_key"

  private let secrets: any SecretStore
  private let logger: Logger

  public init(secrets: any SecretStore, logger: Logger = Logger(label: "bluebubbles.tls")) {
    self.secrets = secrets
    self.logger = logger
  }

  /// Whether both halves are present.
  ///
  /// Both, not either: a certificate without its key cannot bind, and reporting "installed"
  /// for half of a pair sends the caller down the load path to fail there instead.
  public func exists() -> Bool {
    // `try?` on a throwing call returning an Optional flattens to a double Optional, so the
    // presence check has to unwrap both levels — hence `(try? …) ?? nil`.
    let certificate = (try? secrets.get(Self.certificateKey)) ?? nil
    let key = (try? secrets.get(Self.privateKeyKey)) ?? nil
    return certificate?.isEmpty == false && key?.isEmpty == false
  }

  public func load() throws -> CertificateStore.Material? {
    guard let certificate = try secrets.get(Self.certificateKey), !certificate.isEmpty,
      let key = try secrets.get(Self.privateKeyKey), !key.isEmpty
    else { return nil }
    return CertificateStore.Material(certificatePEM: certificate, privateKeyPEM: key)
  }

  /// Stores both halves, then reads them back and compares.
  ///
  /// The read-back is not paranoia about the Keychain: it is what makes it safe for a caller
  /// to delete the disk copy afterwards, and what turns a silent partial write — the
  /// certificate stored, the key rejected — into a thrown error rather than a server that
  /// binds nothing on its next start.
  public func install(_ material: CertificateStore.Material) throws {
    try secrets.set(Self.certificateKey, value: material.certificatePEM)
    try secrets.set(Self.privateKeyKey, value: material.privateKeyPEM)

    guard let stored = try load() else {
      throw CertificateKeychainError.readBackFailed(reason: "nothing was stored")
    }
    guard stored == material else {
      throw CertificateKeychainError.readBackFailed(reason: "the stored bytes differ")
    }
  }

  public func clear() {
    try? secrets.delete(Self.certificateKey)
    try? secrets.delete(Self.privateKeyKey)
  }
}

public enum CertificateKeychainError: Error, Equatable {
  case readBackFailed(reason: String)
}

extension CertificateKeychainError: BBError {
  public var code: String { "certificate.keychain_read_back_failed" }
  public var domain: String { "TLS" }
  public var title: String { "The certificate could not be stored" }
  public var body: String {
    switch self {
    case .readBackFailed(let reason):
      "The TLS certificate was written to the Keychain but could not be read back (\(reason)). "
        + "The copy on disk has been left in place and is still being used."
    }
  }
  public var isUserFacing: Bool { true }
}
