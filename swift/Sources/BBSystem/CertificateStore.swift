//  CertificateStore
//  Where the server's TLS material lives on disk.
//
//  Same layout as the Electron server, so an existing install's certificates are found where
//  they already are: `~/Library/Application Support/bluebubbles-server/Certs/server.pem` and
//  `server.key`, both PEM, plus an `expiration.txt` marker. The paths are part of the
//  migration surface — someone who pointed their DNS at a certificate they installed by hand
//  must not have to install it again.
//
//  On the security of it: these are files, owner-readable, not Keychain items — which is what
//  the current server does and is a deliberate carry-over rather than an oversight.
//
//    - The PRIVATE KEY is the part worth protecting, and the directory is created `0700` with
//      the key itself `0600`, which is the same protection SSH gives `~/.ssh/id_*`.
//    - A Keychain identity would be better against a process running as this user, and is the
//      right eventual home. It is not free: NIOSSL takes PEM or DER bytes, so the key would
//      have to be exported from the Keychain into memory on every bind anyway, and a user
//      importing their own certificate through the UI would need an import flow rather than a
//      file copy. The gain is real but smaller than it looks, and it is not what this pass is
//      for. Recorded as residual risk rather than pretended away.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import Foundation
import Logging

public struct CertificateStore: Sendable {

  public enum StoreError: BBError, Equatable, LocalizedError {
    case missing(path: String)
    case unreadable(path: String, reason: String)
    case notAPEM(path: String)

    public var errorDescription: String? {
      switch self {
      case .missing(let path):
        "No certificate at \(path)"
      case .unreadable(let path, let reason):
        "Could not read \(path): \(reason)"
      case .notAPEM(let path):
        "\(path) is not a PEM file — it should begin with -----BEGIN"
      }
    }
  }

  /// A certificate and its key, as PEM text.
  public struct Material: Sendable, Equatable {
    public let certificatePEM: String
    public let privateKeyPEM: String

    public init(certificatePEM: String, privateKeyPEM: String) {
      self.certificatePEM = certificatePEM
      self.privateKeyPEM = privateKeyPEM
    }
  }

  public let directory: URL
  private let logger: Logger

  public init(
    directory: URL? = nil,
    logger: Logger = Logger(label: "bluebubbles.certificates")
  ) {
    self.directory = directory ?? Self.defaultDirectory
    self.logger = logger
  }

  /// The Electron server's own location, unchanged.
  public static var defaultDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/bluebubbles-server/Certs")
  }

  public var certificateURL: URL { directory.appendingPathComponent("server.pem") }
  public var privateKeyURL: URL { directory.appendingPathComponent("server.key") }
  public var expirationURL: URL { directory.appendingPathComponent("expiration.txt") }

  public var exists: Bool {
    FileManager.default.fileExists(atPath: certificateURL.path)
      && FileManager.default.fileExists(atPath: privateKeyURL.path)
  }

  // MARK: - Reading

  public func load() throws -> Material {
    let certificate = try read(certificateURL)
    let key = try read(privateKeyURL)
    return Material(certificatePEM: certificate, privateKeyPEM: key)
  }

  private func read(_ url: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw StoreError.missing(path: url.path)
    }
    let contents: String
    do {
      contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw StoreError.unreadable(path: url.path, reason: String(describing: error))
    }
    // Checked here rather than at bind time. NIOSSL's error for a non-PEM file is
    // opaque, and "your certificate is not a PEM" is a thing a person can act on.
    guard contents.contains("-----BEGIN") else {
      throw StoreError.notAPEM(path: url.path)
    }
    return contents
  }

  // MARK: - Writing

  /// Installs a certificate and key, replacing whatever was there.
  ///
  /// Validated BEFORE anything is written: a half-installed pair — new certificate, old
  /// key — fails the TLS handshake for every client, and the user's next move is to
  /// restart the server, which does not fix it.
  public func install(_ material: Material) throws {
    guard material.certificatePEM.contains("-----BEGIN") else {
      throw StoreError.notAPEM(path: certificateURL.path)
    }
    guard material.privateKeyPEM.contains("-----BEGIN") else {
      throw StoreError.notAPEM(path: privateKeyURL.path)
    }

    try createDirectory()
    // The certificate is public; the key is not, and is written `0600` — the same
    // protection SSH gives a private key.
    try write(material.certificatePEM, to: certificateURL, permissions: 0o644)
    try write(material.privateKeyPEM, to: privateKeyURL, permissions: 0o600)

    logger.info(
      "Installed a TLS certificate",
      metadata: [
        "path": .string(certificateURL.path)
      ])
  }

  /// Records when the certificate expires, so renewal can be checked without parsing it.
  public func recordExpiration(_ date: Date) throws {
    try createDirectory()
    try write(
      String(Int(date.timeIntervalSince1970)),
      to: expirationURL,
      permissions: 0o644
    )
  }

  public func recordedExpiration() -> Date? {
    guard let text = try? String(contentsOf: expirationURL, encoding: .utf8),
      let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  /// Removes the stored material. Used when regenerating a self-signed certificate.
  public func clear() {
    for url in [certificateURL, privateKeyURL, expirationURL] {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func createDirectory() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // Re-applied on an existing directory: `createDirectory` does not change the
    // permissions of one that is already there, and an install upgraded from a build
    // that created it `0755` would otherwise keep them.
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path
    )
  }

  private func write(_ contents: String, to url: URL, permissions: Int) throws {
    do {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      // After the write: an atomic write replaces the file, and the replacement does
      // not inherit the permissions of what it replaced.
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: url.path
      )
    } catch {
      throw StoreError.unreadable(path: url.path, reason: String(describing: error))
    }
  }
}

extension CertificateStore.StoreError {
  public var code: String {
    switch self {
    case .missing: "certificate.missing"
    case .unreadable: "certificate.unreadable"
    case .notAPEM: "certificate.not_a_p_e_m"
    }
  }

  public var domain: String { "TLS" }

  public var isUserFacing: Bool { true }

  public var title: String { "The configured certificate could not be used" }

  public var body: String { errorDescription ?? "This failed and reported no reason." }
}
