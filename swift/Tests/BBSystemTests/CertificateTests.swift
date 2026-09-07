//  CertificateTests
//  The self-signed certificate, verified by parsing it back.
//
//  Generating a certificate that *looks* right and is rejected at TLS handshake time is easy
//  — a missing SAN, an IP encoded as text, a validity window that starts in the future. All
//  of those produce a file that exists and fails in the field, so the checks here read the
//  certificate back rather than trusting that it was written.

import Foundation
import Testing
import X509

@testable import BBSystem

private func parse(_ generated: GeneratedCertificate) throws -> Certificate {
  try Certificate(pemEncoded: generated.certificatePEM)
}

@Suite("Self-signed certificates")
struct CertificateTests {

  @Test("A generated certificate parses back")
  func roundTrips() throws {
    let generated = try CertificateAuthority.selfSigned()
    #expect(generated.certificatePEM.contains("BEGIN CERTIFICATE"))
    #expect(generated.privateKeyPEM.contains("PRIVATE KEY"))

    let certificate = try parse(generated)
    #expect(certificate.subject == certificate.issuer, "self-signed means these match")
  }

  /// Modern clients ignore the common name entirely and match on SANs. A certificate whose
  /// only identity is its subject fails on every current client.
  @Test("Hostnames land in the subject alternative names")
  func hostnamesInSAN() throws {
    let generated = try CertificateAuthority.selfSigned(
      hostnames: ["bluebubbles.local", "macmini.lan"]
    )
    let names = try #require(
      try parse(generated).extensions.subjectAlternativeNames
    )

    let dnsNames = names.compactMap { name -> String? in
      if case .dnsName(let value) = name { return value }
      return nil
    }
    #expect(dnsNames.contains("bluebubbles.local"))
    #expect(dnsNames.contains("macmini.lan"))
    // Always present: the UI and the helper both reach the server this way.
    #expect(dnsNames.contains("localhost"))
  }

  /// An IP SAN is four raw bytes. Encoding the dotted-quad string instead produces a
  /// certificate that parses fine and silently fails to match the address.
  @Test("IP addresses are encoded as bytes, not as text")
  func ipAddressesAreBytes() throws {
    let generated = try CertificateAuthority.selfSigned(addresses: ["192.168.1.42"])
    let names = try #require(
      try parse(generated).extensions.subjectAlternativeNames
    )

    let ipValues = names.compactMap { name -> [UInt8]? in
      if case .ipAddress(let octets) = name { return Array(octets.bytes) }
      return nil
    }
    #expect(ipValues.contains([192, 168, 1, 42]))
    // Loopback is always included.
    #expect(ipValues.contains([127, 0, 0, 1]))
    // Four bytes, never the fifteen a string would take.
    for value in ipValues { #expect(value.count == 4) }
  }

  @Test("Malformed addresses are skipped rather than failing generation")
  func malformedAddressesSkipped() throws {
    // An unreachable interface or an IPv6 address must not stop the server from having a
    // certificate at all.
    let generated = try CertificateAuthority.selfSigned(
      addresses: ["not-an-ip", "999.1.1.1", "::1", "10.0.0.5"]
    )
    let names = try #require(try parse(generated).extensions.subjectAlternativeNames)
    let ipValues = names.compactMap { name -> [UInt8]? in
      if case .ipAddress(let octets) = name { return Array(octets.bytes) }
      return nil
    }
    #expect(ipValues.contains([10, 0, 0, 5]))
    #expect(ipValues.count == 2, "only the valid address and loopback")
  }

  @Test("Octet parsing rejects everything that is not a dotted quad")
  func octetParsing() {
    #expect(CertificateAuthority.ipv4Octets("192.168.1.1") == [192, 168, 1, 1])
    #expect(CertificateAuthority.ipv4Octets("0.0.0.0") == [0, 0, 0, 0])
    #expect(CertificateAuthority.ipv4Octets("255.255.255.255") == [255, 255, 255, 255])

    #expect(CertificateAuthority.ipv4Octets("256.1.1.1") == nil)
    #expect(CertificateAuthority.ipv4Octets("1.2.3") == nil)
    #expect(CertificateAuthority.ipv4Octets("1.2.3.4.5") == nil)
    #expect(CertificateAuthority.ipv4Octets("hostname") == nil)
    #expect(CertificateAuthority.ipv4Octets("") == nil)
  }

  /// Backdated deliberately. A client whose clock is a few minutes behind would otherwise
  /// reject a certificate issued moments ago — a genuinely baffling failure.
  @Test("Validity starts in the past to tolerate clock skew")
  func validityToleratesSkew() throws {
    let now = Date(timeIntervalSince1970: 1_740_000_000)
    let certificate = try parse(try CertificateAuthority.selfSigned(now: now))

    #expect(certificate.notValidBefore < now)
    #expect(certificate.notValidAfter > now.addingTimeInterval(300 * 24 * 60 * 60))
  }

  /// Renewed before it expires, so a certificate never actually expires in use.
  @Test("Renewal is due before expiry, not at it")
  func renewalWindow() {
    let now = Date()
    #expect(
      !CertificateAuthority.needsRenewal(
        notValidAfter: now.addingTimeInterval(200 * 24 * 60 * 60), now: now
      ))
    #expect(
      CertificateAuthority.needsRenewal(
        notValidAfter: now.addingTimeInterval(10 * 24 * 60 * 60), now: now
      ))
    #expect(
      CertificateAuthority.needsRenewal(
        notValidAfter: now.addingTimeInterval(-1), now: now
      ))
  }

  @Test("The certificate declares server authentication")
  func extendedKeyUsage() throws {
    let certificate = try parse(try CertificateAuthority.selfSigned())
    let usage = try #require(try certificate.extensions.extendedKeyUsage)
    #expect(usage.contains(.serverAuth))
  }

  /// Two servers must not produce the same certificate.
  @Test("Each certificate has its own key and serial")
  func certificatesAreUnique() throws {
    let first = try parse(try CertificateAuthority.selfSigned())
    let second = try parse(try CertificateAuthority.selfSigned())
    #expect(first.serialNumber != second.serialNumber)
    #expect(first.publicKey != second.publicKey)
  }
}
