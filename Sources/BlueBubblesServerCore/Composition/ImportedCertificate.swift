//  ImportedCertificate
//  Installing a TLS certificate the person supplied: the one sequence the Security page's
//  import and a restored archive share.
//
//  Three steps, in this order, and each order is a decision. The material is VALIDATED
//  first (`CertificateAuthority.validate`): a key that is not the certificate's, or a
//  certificate already expired, binds and then fails every client's handshake with nothing
//  on the server saying why. It is stored next, and `CertificateKeychainStore.install`
//  verifies by reading back, which is what makes it safe to clear what an older build left
//  in `Certs/` (whose missing `expiration.txt` would otherwise read as "the user's own" for
//  a stale certificate). Provenance is recorded LAST, by the caller through its own door to
//  the settings, because recording "the user's own" before the material is there would
//  describe a certificate that does not exist.
//
//  The provenance is `imported` with a ZERO expiry. That field is the renewal clock, and an
//  imported certificate is never renewed by this server: watching its expiry is the user's
//  job, and a real date there would invite the renewer to act on it. See `TLSProvisioning`.
//
//  It is not reloaded. The listener reads its material once, at start, so like every other
//  change to the certificate this one takes effect when the server next starts.

import BBSettings
import BBSystem
import Foundation

public enum ImportedCertificate {

  /// Validates and stores `material`, and clears what an older build left on disk.
  ///
  /// Returns once the Keychain verifiably holds it. The caller records `provenance` next.
  public static func install(
    _ material: CertificateStore.Material,
    keychain: CertificateKeychainStore,
    legacyFiles: CertificateStore,
    now: Date = Date()
  ) async throws {
    _ = try CertificateAuthority.validate(
      certificatePEM: material.certificatePEM, privateKeyPEM: material.privateKeyPEM, now: now)
    try await keychain.install(material)
    legacyFiles.clear()
  }

  /// What an installed certificate records about itself. See the header.
  @Sendable
  public static func provenance(_ batch: inout SettingsBatch) throws {
    try batch.set(Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.imported.rawValue)
    try batch.set(Settings.tlsCertificateExpiresAt, to: 0)
  }
}
