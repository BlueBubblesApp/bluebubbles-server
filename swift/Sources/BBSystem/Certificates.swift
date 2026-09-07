//  Certificates
//  The self-signed certificate for the HTTPS listener.
//
//  Replaces `node-forge` plus `@peculiar/x509` — two JavaScript crypto libraries carried
//  solely to generate one certificate. `swift-certificates` is Apple-maintained and the key
//  generation goes through `swift-crypto`, so no key material is produced by hand.
//
//  What this certificate is and is not
//  -----------------------------------
//  It is self-signed, so no client will trust it without being told to. That is fine for its
//  actual job — encrypting a LAN connection between a user's own devices — and it is why the
//  tunnels exist for anything reachable from the internet, since they terminate TLS with a
//  real certificate.
//
//  See `.claude/docs/performance.md`.

import BBCore
import Crypto
import Foundation
import Logging
import SwiftASN1
import X509

public enum CertificateError: BBError, Equatable {
  case generationFailed(reason: String)
  case notFound
}

public struct GeneratedCertificate: Sendable {
  /// PEM, for handing to a TLS configuration.
  public let certificatePEM: String
  public let privateKeyPEM: String
  public let notValidAfter: Date

  public init(certificatePEM: String, privateKeyPEM: String, notValidAfter: Date) {
    self.certificatePEM = certificatePEM
    self.privateKeyPEM = privateKeyPEM
    self.notValidAfter = notValidAfter
  }
}

public enum CertificateAuthority {

  /// A year. Long enough not to be a recurring chore, short enough that a leaked key has a
  /// bounded life — and the server regenerates automatically, so expiry costs the user
  /// nothing.
  public static let validity: TimeInterval = 365 * 24 * 60 * 60
  /// Regenerated this far before expiry, so a certificate never actually expires in use.
  public static let renewalWindow: TimeInterval = 30 * 24 * 60 * 60

  /// Generates a self-signed certificate for the given hostnames.
  ///
  /// - Parameter hostnames: Every name and address a client might use. All of them go in
  ///   the SAN extension, because a certificate valid only for the name in its subject
  ///   fails for the IP address a LAN client actually connects to — and modern clients
  ///   ignore the common name entirely.
  public static func selfSigned(
    commonName: String = "BlueBubbles Server",
    hostnames: [String] = [],
    addresses: [String] = [],
    now: Date = Date()
  ) throws -> GeneratedCertificate {
    // P-256 rather than RSA: smaller, faster to generate, and universally supported by
    // anything that speaks modern TLS.
    let key = P256.Signing.PrivateKey()
    let certificateKey = Certificate.PrivateKey(key)

    let name = try DistinguishedName {
      CommonName(commonName)
      OrganizationName("BlueBubbles")
    }

    var alternativeNames: [GeneralName] = hostnames.map { .dnsName($0) }
    // `localhost` is always included: the UI and the helper both reach the server that
    // way, and a certificate without it breaks them on a LAN-only install.
    if !hostnames.contains("localhost") {
      alternativeNames.append(.dnsName("localhost"))
    }
    for address in addresses + ["127.0.0.1"] {
      guard let octets = Self.ipv4Octets(address) else { continue }
      // An IP SAN is four raw bytes, not the text form — encoding the string would
      // produce a certificate that silently fails to match the address.
      alternativeNames.append(.ipAddress(ASN1OctetString(contentBytes: octets[...])))
    }

    let notValidAfter = now.addingTimeInterval(validity)

    do {
      let certificate = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(),
        publicKey: certificateKey.publicKey,
        // Backdated slightly. A client whose clock is a few minutes behind the
        // server's would otherwise reject a certificate issued moments ago, which is
        // a genuinely baffling failure to debug.
        notValidBefore: now.addingTimeInterval(-3600),
        notValidAfter: notValidAfter,
        issuer: name,
        subject: name,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: try Certificate.Extensions {
          Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
          Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
          try ExtendedKeyUsage([.serverAuth])
          SubjectAlternativeNames(alternativeNames)
        },
        issuerPrivateKey: certificateKey
      )

      return GeneratedCertificate(
        certificatePEM: try certificate.serializeAsPEM().pemString,
        privateKeyPEM: key.pemRepresentation,
        notValidAfter: notValidAfter
      )
    } catch {
      throw CertificateError.generationFailed(reason: String(describing: error))
    }
  }

  /// Whether a certificate should be replaced.
  public static func needsRenewal(
    notValidAfter: Date,
    now: Date = Date()
  ) -> Bool {
    notValidAfter.timeIntervalSince(now) < renewalWindow
  }

  /// Parses dotted-quad IPv4 into its four bytes.
  ///
  /// Returns nil for anything else, including IPv6 — which belongs in a SAN too, but as a
  /// sixteen-byte value, and no supported deployment needs it yet.
  static func ipv4Octets(_ address: String) -> [UInt8]? {
    let parts = address.split(separator: ".")
    guard parts.count == 4 else { return nil }
    let octets = parts.compactMap { UInt8($0) }
    return octets.count == 4 ? octets : nil
  }
}

extension CertificateError {
  public var code: String {
    switch self {
    case .generationFailed: "certificate.generation_failed"
    case .notFound: "certificate.not_found"
    }
  }

  public var domain: String { "TLS" }

  /// A server that cannot produce its certificate cannot serve HTTPS, and the user chose
  /// HTTPS — so this has to be said rather than logged.
  public var isUserFacing: Bool { true }

  public var title: String { "The server's certificate is unavailable" }

  public var body: String {
    switch self {
    case .generationFailed(let reason):
      "A self-signed certificate could not be generated: \(reason)"
    case .notFound:
      "No certificate was found, so this server cannot serve over HTTPS."
    }
  }
}
