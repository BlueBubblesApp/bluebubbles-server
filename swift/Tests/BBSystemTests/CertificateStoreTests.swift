//  CertificateStoreTests
//  Where the TLS material lives, and what must never happen to it.
//
//  The rule with the most consequence is that a certificate the USER installed is never
//  regenerated, renewed or deleted. Losing one somebody paid for and installed is not
//  recoverable from the server's side, and the current implementation guards every mutation
//  with `usingCustomPaths` for exactly that reason.

import Foundation
import Testing

@testable import BBSystem

@Suite("Certificate store")
struct CertificateStoreTests {

  private func makeStore() -> CertificateStore {
    CertificateStore(
      directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bb-certs-\(UUID().uuidString)")
    )
  }

  private func material() throws -> CertificateStore.Material {
    let generated = try CertificateAuthority.selfSigned(hostnames: ["localhost"])
    return CertificateStore.Material(
      certificatePEM: generated.certificatePEM,
      privateKeyPEM: generated.privateKeyPEM
    )
  }

  @Test("Material round-trips through the store")
  func roundTrip() throws {
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let original = try material()
    #expect(!store.exists)
    try store.install(original)
    #expect(store.exists)
    #expect(try store.load() == original)
  }

  @Test("The private key is written owner-only")
  func privateKeyIsProtected() throws {
    // The same protection SSH gives `~/.ssh/id_*`. An atomic write REPLACES the file, so
    // permissions have to be applied after the write rather than before — a detail that
    // is easy to get wrong and impossible to notice.
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try store.install(try material())

    let keyMode =
      try FileManager.default
      .attributesOfItem(atPath: store.privateKeyURL.path)[.posixPermissions] as? Int
    #expect(keyMode == 0o600, "the private key is readable by other users")

    let directoryMode =
      try FileManager.default
      .attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
    #expect(directoryMode == 0o700)
  }

  @Test("An existing directory has its permissions corrected")
  func existingDirectoryIsTightened() throws {
    // `createDirectory` does not change the permissions of a directory that is already
    // there, so an install upgraded from a build that created it 0755 would keep them.
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try FileManager.default.createDirectory(
      at: store.directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )

    try store.install(try material())
    let mode =
      try FileManager.default
      .attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
  }

  @Test("A non-PEM file is refused before anything is written")
  func nonPEMIsRefused() throws {
    // Validated up front because a HALF-installed pair — new certificate, old key —
    // fails the handshake for every client, and restarting does not fix it.
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let valid = try material()

    #expect(throws: CertificateStore.StoreError.self) {
      try store.install(
        CertificateStore.Material(
          certificatePEM: "this is not a certificate",
          privateKeyPEM: valid.privateKeyPEM
        )
      )
    }
    #expect(!store.exists, "a rejected install left files behind")

    #expect(throws: CertificateStore.StoreError.self) {
      try store.install(
        CertificateStore.Material(
          certificatePEM: valid.certificatePEM,
          privateKeyPEM: "not a key"
        )
      )
    }
    #expect(!store.exists)
  }

  @Test("A missing certificate reports its path")
  func missingReportsPath() {
    let store = makeStore()
    #expect(throws: CertificateStore.StoreError.self) { _ = try store.load() }
  }

  @Test("An expiry marker round-trips to the second")
  func expirationRoundTrips() throws {
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    try store.recordExpiration(expiry)
    #expect(store.recordedExpiration() == expiry)
  }

  /// The rule that protects a user's own certificate.
  @Test("A certificate with no expiry marker is treated as user-supplied")
  func userSuppliedCertificatesHaveNoMarker() throws {
    // `expiration.txt` is written by generation and by nothing else, so its absence IS
    // the signal that the material came from the user. Renewal keys on that, which is
    // what stops the server replacing a certificate somebody bought.
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    try store.install(try material())
    #expect(store.recordedExpiration() == nil)
    #expect(store.exists)
  }

  @Test("Clearing removes the material and its marker")
  func clearRemovesEverything() throws {
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try store.install(try material())
    try store.recordExpiration(Date())

    store.clear()
    #expect(!store.exists)
    #expect(store.recordedExpiration() == nil)
  }

  @Test("The default location matches the Electron server's")
  func defaultPathIsUnchanged() {
    // Part of the migration surface: someone who installed a certificate by hand must
    // not have to install it again.
    #expect(
      CertificateStore.defaultDirectory.path.hasSuffix(
        "Library/Application Support/bluebubbles-server/Certs"
      ))
    let store = CertificateStore()
    #expect(store.certificateURL.lastPathComponent == "server.pem")
    #expect(store.privateKeyURL.lastPathComponent == "server.key")
  }
}
