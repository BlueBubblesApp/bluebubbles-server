//  TLSProvisioning
//  Deciding whether the server terminates TLS, and with what.
//
//  The feature is for the deployment that terminates TLS ITSELF, rather than behind
//  Cloudflare or nginx: a dynamic-DNS install where clients connect straight to this machine.
//  In that shape the alternative to this is plaintext iMessage content over the internet.
//
//  Two rules:
//
//    - A user-supplied certificate is NEVER regenerated or deleted. Silently replacing a
//      certificate somebody paid for and installed is unrecoverable from the server's side.
//    - A self-signed certificate IS renewed automatically, well before expiry. An expired
//      certificate fails every client at once, and nobody is watching for it.
//
//  See `.claude/docs/architecture.md`.

import BBBuiltIns
import BBDiagnostics
import BBInterfaces
import BBSettings
import BBSystem
import Foundation
import Logging

public enum TLSProvisioning {

  /// Resolves the material the listener should bind with, or nil for plaintext.
  ///
  /// Returning nil is the ordinary case: most installs sit behind a tunnel that terminates
  /// TLS for them, and adding a second layer inside it buys nothing.
  public static func material(
    settings: ScopedSettings,
    store: CertificateStore,
    keychain: CertificateKeychainStore,
    alerts: AlertCenter?,
    logger: Logger
  ) async -> CertificateStore.Material? {
    guard await settings.valueOrDefault(Settings.useCustomCertificate) else { return nil }

    // The Keychain is the store. `CertificateStore` is a SOURCE, read once to adopt what an
    // older build (or the Electron server) left in `Certs/`, and nothing writes to it.
    if let material = try? await keychain.load(), material.certificatePEM.isEmpty == false {
      return await renewIfNeeded(
        keychain: keychain, material: material, settings: settings, alerts: alerts,
        logger: logger)
    }

    // Files present and the Keychain empty: adopt them, then remove them.
    //
    // The order is the whole safety argument. `keychain.install` verifies by reading back and
    // throws otherwise, and `store.clear()` runs only after it returns, so the files go only
    // once something else definitely holds the material, and a failure leaves them exactly
    // where they are with the server binding TLS from them for this run.
    if store.exists {
      // Two failures, and they are not the same failure. Material that cannot be READ leaves
      // nothing to serve; material that cannot be ADOPTED is still perfectly good material
      // that happens to be in the wrong place. Handling both in one `catch` is what made a
      // Keychain that refused a write drop the server to plain HTTP over a certificate it had
      // already loaded successfully.
      let material: CertificateStore.Material
      do {
        material = try store.load()
      } catch {
        // Reported loudly and NOT silently regenerated. A certificate that is present but
        // unreadable is far more likely to be a permissions problem or a bad paste than a
        // reason to throw the user's certificate away.
        logger.error(
          "The configured TLS certificate could not be read",
          metadata: ["error": .string(String(describing: error))])
        await alerts?.raise(
          UserAlert(
            severity: .error,
            title: "Your TLS certificate could not be read",
            body: "\(error) The server is not starting with TLS. Re-import the "
              + "certificate on the Security page, or turn off custom "
              + "certificates to serve over plain HTTP.",
            source: "Certificates",
            actions: [.openSettings(.security)],
            dedupeKey: "tls.unreadable"
          )
        )
        return nil
      }

      // Provenance comes from the file marker, and only `generate` ever wrote one, so its
      // ABSENCE means the user installed this, which is the value that stops the renewer. It
      // has to be read before the files go, and it must not overwrite a record that already
      // exists: a `tls_certificate_origin` written by the import view or the migration runner
      // is better evidence than a file that may predate both.
      let alreadyRecorded = await settings.valueOrDefault(Settings.tlsCertificateExpiresAt) > 0
      let marker = store.recordedExpiration()

      do {
        try await keychain.install(material)
      } catch {
        // The files are untouched (`store.clear()` is below this, not above it) so the
        // server is exactly where it was before it tried, and that means serving TLS from
        // them. Renewal is skipped rather than attempted: a store that will not accept this
        // write will not accept a renewed certificate either, and generating one only to
        // discard it would replace a working certificate with nothing.
        logger.error(
          "The TLS certificate could not be moved into the Keychain",
          metadata: ["error": .string(String(describing: error))])
        await alerts?.raise(
          UserAlert(
            severity: .warning,
            title: "Your TLS certificate could not be moved to the Keychain",
            body: "\(error) HTTPS is working; the certificate is being served from its "
              + "files, which have been left in place. This will be retried the next time "
              + "the server starts.",
            source: "Certificates",
            dedupeKey: "tls.adoption-failed"
          )
        )
        return material
      }

      store.clear()
      logger.info("Adopted the TLS certificate from disk into the Keychain")

      // After the files are gone, and unconditionally. If this throws, the material is in the
      // Keychain with no recorded origin, which reads as `.imported` and is therefore never
      // renewed. That is the fail-safe direction: a certificate left alone forever is
      // recoverable by re-importing, one silently replaced is not.
      if !alreadyRecorded {
        let origin: TLSCertificateOrigin = marker == nil ? .imported : .selfSigned
        try? await settings.set(Settings.tlsCertificateOrigin, to: origin.rawValue)
        try? await settings.set(
          Settings.tlsCertificateExpiresAt,
          to: marker.map { Int($0.timeIntervalSince1970) } ?? 0)
      }

      return await renewIfNeeded(
        keychain: keychain, material: material, settings: settings, alerts: alerts,
        logger: logger)
    }

    // Nothing anywhere, but the settings may still say something was here.
    //
    // This is the restore case, and it is worth naming: Keychain items are
    // `AfterFirstUnlockThisDeviceOnly`, so they do not travel in a backup or through Migration
    // Assistant. On a new Mac a self-signed certificate is regenerated below and nobody needs
    // to care, but an IMPORTED one is simply gone, and generating a self-signed replacement
    // without saying so would present a certificate the user never chose under a hostname
    // their clients already trust.
    // An EXPLICIT `imported`, not the fail-safe one. `TLSCertificateOrigin` maps an unset row
    // to `.imported` on purpose, so testing the enum alone would fire this on every fresh
    // install that has never had a certificate at all.
    let recordedOrigin = await settings.valueOrDefault(Settings.tlsCertificateOrigin)
    if recordedOrigin == TLSCertificateOrigin.imported.rawValue {
      logger.warning("An imported TLS certificate is recorded but no material can be found")
      await alerts?.raise(
        UserAlert(
          severity: .warning,
          title: "Your imported TLS certificate is missing",
          body: "This server was using a certificate you supplied, and it is no longer "
            + "available: Keychain items do not transfer to a new Mac or restore from a "
            + "backup. A self-signed certificate has been generated so HTTPS keeps working. "
            + "Import yours again on the Security page to go back to it.",
          source: "Certificates",
          actions: [.openSettings(.security)],
          dedupeKey: "tls.imported-missing"
        )
      )
    }

    // Generate, so turning the setting on produces a working HTTPS server rather than an
    // instruction to go and find a certificate.
    return await generate(
      settings: settings, keychain: keychain, alerts: alerts, logger: logger)
  }

  /// Replaces a self-signed certificate that is close to expiry, and returns what to bind.
  ///
  /// Only ever a certificate this server generated; see the origin rule below.
  ///
  /// **It returns the material rather than writing and letting the caller re-read.** A
  /// re-read is only correct if every store this wrote holds the same thing, which is
  /// precisely the property that breaks first, and it breaks silently, because a renewal
  /// that reaches one store still succeeds and still binds. Returning the value removes the
  /// question.
  private static func renewIfNeeded(
    keychain: CertificateKeychainStore,
    material: CertificateStore.Material,
    settings: ScopedSettings,
    alerts: AlertCenter?,
    logger: Logger
  ) async -> CertificateStore.Material {
    // Recorded provenance first, falling back to the file marker for an install that has not
    // been through the certificate migration yet.
    //
    // Both express the SAME fail-safe rule and it must not invert: only a certificate this
    // server generated is ever replaced. An unknown origin means the user installed it.
    let recordedOrigin = TLSCertificateOrigin(
      rawValue: await settings.valueOrDefault(Settings.tlsCertificateOrigin))
    let recordedExpiry = await settings.valueOrDefault(Settings.tlsCertificateExpiresAt)
    let hasRecord = recordedExpiry > 0

    if hasRecord {
      guard recordedOrigin == .selfSigned else {
        logger.debug("Certificate is recorded as user-supplied; leaving it alone")
        return material
      }
    }

    // No record at all means nothing has ever claimed this certificate as ours: material
    // that reached the Keychain by some path that did not record provenance. Fail safe in the
    // same direction as everything else here and leave it alone.
    guard hasRecord else {
      logger.debug("Certificate has no recorded expiry; treating it as user-supplied")
      return material
    }
    let expiry = Date(timeIntervalSince1970: TimeInterval(recordedExpiry))
    guard CertificateAuthority.needsRenewal(notValidAfter: expiry) else { return material }

    logger.info(
      "Renewing the self-signed TLS certificate",
      metadata: [
        "expiresAt": .string(String(describing: expiry))
      ])
    do {
      let generated = try CertificateAuthority.selfSigned(hostnames: hostnames())
      let renewed = CertificateStore.Material(
        certificatePEM: generated.certificatePEM,
        privateKeyPEM: generated.privateKeyPEM
      )
      try await persist(
        renewed, expiry: generated.notValidAfter, origin: .selfSigned,
        keychain: keychain, settings: settings, logger: logger)
      return renewed
    } catch {
      // The existing certificate is still valid for at least the renewal window, so a
      // failed renewal is not urgent: it is retried on the next start.
      logger.warning(
        "Could not renew the TLS certificate",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return material
    }
  }

  /// Stores material and records what it is, in one step.
  ///
  /// **The Keychain is the only store.** `Certs/server.pem` and `server.key` are read once, to
  /// adopt what an older build left there, and then deleted; nothing writes them. A live
  /// second copy would mean keeping two stores in step forever to buy a fallback only an
  /// unsigned build could reach, and an unsigned build cannot read what a signed one wrote
  /// in any case, because the two talk to different keychains.
  ///
  /// **The settings rows are written here because they ARE the renewal clock.** Nothing else
  /// writes them but the migration runner, the import view and the adoption path above, so a
  /// renewal that replaces the material and leaves `tls_certificate_expires_at` alone leaves
  /// `needsRenewal` permanently true: the server renews on every start for the rest of its
  /// life, and the loop is invisible because each renewal succeeds.
  ///
  /// The material goes in before the clock moves. A clock advanced past material that failed
  /// to store would describe a certificate the server does not have, and would stop the
  /// renewer from trying again.
  private static func persist(
    _ material: CertificateStore.Material,
    expiry: Date,
    origin: TLSCertificateOrigin,
    keychain: CertificateKeychainStore,
    settings: ScopedSettings,
    logger: Logger
  ) async throws {
    try await keychain.install(material)
    try await settings.set(Settings.tlsCertificateOrigin, to: origin.rawValue)
    try await settings.set(
      Settings.tlsCertificateExpiresAt, to: Int(expiry.timeIntervalSince1970))
  }

  private static func generate(
    settings: ScopedSettings,
    keychain: CertificateKeychainStore,
    alerts: AlertCenter?,
    logger: Logger
  ) async -> CertificateStore.Material? {
    do {
      // The published address goes in the SAN, so a client connecting by the name the
      // server told it about gets a certificate that matches. A certificate valid only
      // for "localhost" is rejected by every client that is not on this machine.
      let address = await settings.valueOrDefault(Settings.serverAddress)
      let generated = try CertificateAuthority.selfSigned(
        hostnames: hostnames(publishedAddress: address)
      )
      let material = CertificateStore.Material(
        certificatePEM: generated.certificatePEM,
        privateKeyPEM: generated.privateKeyPEM
      )
      try await persist(
        material, expiry: generated.notValidAfter, origin: .selfSigned,
        keychain: keychain, settings: settings, logger: logger)

      logger.info(
        "Generated a self-signed TLS certificate",
        metadata: [
          "expiresAt": .string(String(describing: generated.notValidAfter))
        ])
      // Said once, plainly. A self-signed certificate makes clients complain, and a
      // user who does not know the server generated one has no way to interpret that.
      await alerts?.raise(
        UserAlert(
          severity: .info,
          title: "The server generated its own TLS certificate",
          body: "It is self-signed, so clients will warn that it is not trusted "
            + "until you accept it once. To use your own certificate instead, "
            + "import it on the Security page.",
          source: "Certificates",
          actions: [.openSettings(.security)],
          dedupeKey: "tls.self-signed"
        )
      )
      return material
    } catch {
      logger.error(
        "Could not generate a TLS certificate",
        metadata: [
          "error": .string(String(describing: error))
        ])
      await alerts?.raise(
        UserAlert(
          severity: .error,
          title: "Could not set up HTTPS",
          body: "\(error) The server is running over plain HTTP.",
          source: "Certificates",
          dedupeKey: "tls.generation-failed"
        )
      )
      return nil
    }
  }

  /// Every name a client might connect by.
  ///
  /// All of them, because a certificate valid only for the subject's common name fails for
  /// the IP a LAN client actually dials, and modern clients ignore the common name.
  ///
  /// Every candidate is filtered through `dnsName`. That is not defensive tidying: a SAN
  /// dNSName is an ASN.1 IA5String, so a single non-ASCII byte makes the whole certificate
  /// unencodable and generation throws. The Mac's own name is the reliable source of one:
  /// the macOS default is "<Name>’s MacBook Pro", with a U+2019 apostrophe, so a freshly
  /// installed server with HTTPS switched on failed to generate a certificate at all, and
  /// silently served plaintext instead.
  static func hostnames(publishedAddress: String = "") -> [String] {
    var names = ["localhost"]

    // The Mac's `.local` name, which is what a LAN client resolves. Derived from the
    // computer name the way Bonjour does: non-alphanumerics become hyphens.
    if let machine = Host.current().localizedName.flatMap(bonjourName) {
      names.append(machine)
      names.append("\(machine).local")
    }

    let trimmed =
      publishedAddress
      .replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")
      .split(separator: "/").first
      .map(String.init) ?? ""
    // The port is not part of a certificate name.
    let host = trimmed.split(separator: ":").first.map(String.init) ?? ""
    names.append(host)

    return Array(Set(names.compactMap(dnsName))).sorted()
  }

  /// A candidate reduced to a valid DNS name, or nil if nothing usable is left.
  ///
  /// Labels are ASCII letters, digits and hyphens, and may not begin or end with a hyphen.
  /// Anything else (a space, a smart apostrophe, an emoji) is dropped rather than
  /// substituted, because a name nobody will ever connect by is worth nothing in a
  /// certificate and an invalid one costs the whole certificate.
  static func dnsName(_ candidate: String) -> String? {
    let labels = candidate.lowercased().split(separator: ".").map { label -> String in
      String(
        label.map { character in
          character.isASCII && (character.isLetter || character.isNumber || character == "-")
            ? character
            : "-"
        }
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    let usable = labels.filter { !$0.isEmpty && $0.count <= 63 }
    guard !usable.isEmpty else { return nil }
    let joined = usable.joined(separator: ".")
    // 253 is the maximum length of a DNS name.
    guard joined.count <= 253 else { return nil }
    return joined
  }

  /// The Bonjour host name macOS derives from the computer name.
  ///
  /// "Zach's MacBook Pro" becomes "zachs-macbook-pro", which is the name a client on the
  /// same network actually resolves, and the one worth having in the certificate.
  static func bonjourName(_ computerName: String) -> String? {
    // The apostrophe is REMOVED rather than hyphenated, matching macOS: the Bonjour name
    // for "Zach's MacBook Pro" is "zachs-macbook-pro", not "zach-s-macbook-pro".
    let withoutApostrophes =
      computerName
      .replacingOccurrences(of: "\u{2019}", with: "")
      .replacingOccurrences(of: "'", with: "")
    return dnsName(withoutApostrophes)
  }
}
