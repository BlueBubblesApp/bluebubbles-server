//  TLSProvisioning
//  Deciding whether the server terminates TLS, and with what.
//
//  `use_custom_certificate` has existed as a setting since the migration began and did
//  nothing: `Certificates` could generate a self-signed certificate and nothing consumed it,
//  and the listener bound plain HTTP unconditionally. So a user who turned it on got an
//  unencrypted server and no indication that anything had failed.
//
//  The feature is for the deployment that terminates TLS ITSELF, rather than behind
//  Cloudflare or nginx: a dynamic-DNS install where clients connect straight to this machine.
//  In that shape the alternative to this is plaintext iMessage content over the internet.
//
//  Two rules, both learned from the current implementation:
//
//    - A user-supplied certificate is NEVER regenerated or deleted. The current server
//      guards every mutation with `usingCustomPaths` for exactly this reason: silently
//      replacing a certificate somebody paid for and installed is unrecoverable from the
//      server's side.
//    - A self-signed certificate IS renewed automatically, well before expiry. An expired
//      certificate fails every client at once, and nobody is watching for it.
//
//  See `.claude/docs/architecture.md`.

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
    settings: SettingsStore,
    store: CertificateStore,
    alerts: AlertCenter?,
    logger: Logger
  ) async -> CertificateStore.Material? {
    guard await settings.get(Settings.useCustomCertificate) else { return nil }

    // An installed certificate wins, always. It is either the user's own or one this
    // server generated earlier, and either way replacing it is not this function's
    // decision to make.
    if store.exists {
      do {
        let material = try store.load()
        await renewIfNeeded(store: store, material: material, logger: logger)
        return try store.load()
      } catch {
        // Reported loudly and NOT silently regenerated. A certificate that is present
        // but unreadable is far more likely to be a permissions problem or a bad
        // paste than a reason to throw the user's certificate away.
        logger.error(
          "The configured TLS certificate could not be read",
          metadata: [
            "error": .string(String(describing: error))
          ])
        await alerts?.raise(
          UserAlert(
            severity: .error,
            title: "Your TLS certificate could not be read",
            body: "\(error) The server is not starting with TLS. Re-import the "
              + "certificate on the Security page, or turn off custom "
              + "certificates to serve over plain HTTP.",
            source: "Certificates",
            actions: [.openSettings(section: "security")],
            dedupeKey: "tls.unreadable"
          )
        )
        return nil
      }
    }

    // Nothing installed: generate one, so turning the setting on produces a working
    // HTTPS server rather than an instruction to go and find a certificate.
    return await generate(settings: settings, store: store, alerts: alerts, logger: logger)
  }

  /// Replaces a self-signed certificate that is close to expiry.
  ///
  /// Only ever a certificate this server generated. `expiration.txt` is written by
  /// `generate` and by nothing else, so its absence means the material was installed by the
  /// user — which is precisely the case that must not be touched.
  private static func renewIfNeeded(
    store: CertificateStore,
    material: CertificateStore.Material,
    logger: Logger
  ) async {
    guard let expiry = store.recordedExpiration() else {
      logger.debug("Certificate has no expiry marker; treating it as user-supplied")
      return
    }
    guard CertificateAuthority.needsRenewal(notValidAfter: expiry) else { return }

    logger.info(
      "Renewing the self-signed TLS certificate",
      metadata: [
        "expiresAt": .string(String(describing: expiry))
      ])
    do {
      let generated = try CertificateAuthority.selfSigned(hostnames: hostnames())
      try store.install(
        CertificateStore.Material(
          certificatePEM: generated.certificatePEM,
          privateKeyPEM: generated.privateKeyPEM
        )
      )
      try store.recordExpiration(generated.notValidAfter)
    } catch {
      // The existing certificate is still valid for at least the renewal window, so a
      // failed renewal is not urgent — it is retried on the next start.
      logger.warning(
        "Could not renew the TLS certificate",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  private static func generate(
    settings: SettingsStore,
    store: CertificateStore,
    alerts: AlertCenter?,
    logger: Logger
  ) async -> CertificateStore.Material? {
    do {
      // The published address goes in the SAN, so a client connecting by the name the
      // server told it about gets a certificate that matches. A certificate valid only
      // for "localhost" is rejected by every client that is not on this machine.
      let address = await settings.get(Settings.serverAddress)
      let generated = try CertificateAuthority.selfSigned(
        hostnames: hostnames(publishedAddress: address)
      )
      let material = CertificateStore.Material(
        certificatePEM: generated.certificatePEM,
        privateKeyPEM: generated.privateKeyPEM
      )
      try store.install(material)
      try store.recordExpiration(generated.notValidAfter)

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
          actions: [.openSettings(section: "security")],
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
  /// unencodable and generation throws. The Mac's own name is the reliable source of one —
  /// the macOS default is "<Name>’s MacBook Pro", with a U+2019 apostrophe — so a freshly
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
  /// Anything else — a space, a smart apostrophe, an emoji — is dropped rather than
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
  /// same network actually resolves — and the one worth having in the certificate.
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
