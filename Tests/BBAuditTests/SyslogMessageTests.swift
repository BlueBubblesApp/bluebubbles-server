//  SyslogMessageTests
//  An audit record as RFC 5424, byte for byte where the standard cares.
//
//  A receiver parses the header by position and by the standard's limits, so the PRI
//  arithmetic, the field order, the 32-character MSGID and the octet count are each a thing a
//  receiver rejects a message for, silently, when they are wrong.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBAudit

@Suite("Syslog message")
struct SyslogMessageTests {

  private let event = AuditEvent(
    kind: .credentialRejected, outcome: .denied, actor: .client(address: "203.0.113.9"),
    source: .http, route: "/api/v1/ping", subject: .client("203.0.113.9"),
    summary: "A credential from 203.0.113.9 was rejected on /api/v1/ping.",
    metadata: ["reason": .string("password_mismatch"), "transport": .string("http")],
    occurredAt: Date(timeIntervalSince1970: 1_700_000_000))

  @Test("PRI is facility times eight plus severity")
  func priority() {
    #expect(SyslogMessage.priority(facility: .local0, severity: .info) == 134)
    #expect(SyslogMessage.priority(facility: .local0, severity: .warning) == 132)
    #expect(SyslogMessage.priority(facility: .auth, severity: .critical) == 34)
    #expect(SyslogMessage.priority(facility: .user, severity: .notice) == 13)
  }

  @Test("The header is the standard's seven fields in order, then the JSON body")
  func layout() throws {
    let message = SyslogMessage.format(
      event, hostname: "mac.example.com", processID: 4242, facility: .local0,
      softwareVersion: "1.2.3")
    let parts = message.split(separator: " ", maxSplits: 7).map(String.init)
    #expect(parts.count == 8)
    // A rejected credential is a warning: 16 * 8 + 4.
    #expect(parts[0] == "<132>1")
    #expect(parts[1] == "2023-11-14T22:13:20.000Z")
    #expect(parts[2] == "mac.example.com")
    #expect(parts[3] == "bluebubbles-server")
    #expect(parts[4] == "4242")
    // MSGID is the CATEGORY, which fits the 32-character cap where several kinds do not.
    #expect(parts[5] == "auth")
    #expect(parts[6] == "[origin software=\"bluebubbles-server\" swVersion=\"1.2.3\"]")

    let body = try #require(parts[7].data(using: .utf8))
    let document = try AuditJSON.decode(AuditValue.self, from: body)
    guard case .object(let fields) = document else {
      Issue.record("the body is not a JSON object")
      return
    }
    #expect(fields["kind"] == .string("auth.credential_rejected"))
    #expect(fields["host"] == .string("mac.example.com"))
    #expect(
      fields["metadata"]
        == .object(["reason": .string("password_mismatch"), "transport": .string("http")]))
  }

  @Test("Without a version the structured data is the nil value")
  func noVersionMeansNilSD() {
    let message = SyslogMessage.format(
      event, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil)
    let parts = message.split(separator: " ", maxSplits: 7).map(String.init)
    #expect(parts[6] == "-")
  }

  @Test("Every category fits MSGID's cap, and no kind would")
  func messageIDFits() {
    for category in AuditCategory.allCases {
      #expect(category.rawValue.count <= SyslogMessage.messageIDLimit)
    }
    // The reason the category is the MSGID: at least one kind is too long for the field.
    #expect(AuditEventKind.allCases.contains { $0.rawValue.count > SyslogMessage.messageIDLimit })
  }

  @Test("A header token is printable ASCII with no spaces, cut to the limit, never empty")
  func headerToken() {
    #expect(SyslogMessage.headerToken("my mac.local", limit: 255) == "mymac.local")
    #expect(SyslogMessage.headerToken("héllo", limit: 255) == "hllo")
    #expect(SyslogMessage.headerToken("abcdef", limit: 3) == "abc")
    #expect(SyslogMessage.headerToken("   ", limit: 255) == "-")
    #expect(SyslogMessage.headerToken("", limit: 255) == "-")
  }

  @Test("An SD-PARAM value escapes the three characters the standard names")
  func parameterValue() {
    #expect(SyslogMessage.parameterValue(#"a"b\c]d"#) == #"a\"b\\c\]d"#)
  }

  @Test("Octet counting prefixes the byte length, not the character count")
  func octetCounting() {
    let message = "<134>1 - - - - - - héllo"
    let frame = SyslogMessage.octetCountedFrame(message)
    #expect(frame == "\(message.utf8.count) \(message)")
    #expect(message.utf8.count == message.count + 1, "the accent is two bytes")
  }

  // MARK: - Configuration

  @Test("Facility and transport parse their stored spelling and default sensibly")
  func parsing() {
    #expect(SyslogFacility.parse("local3") == .local3)
    #expect(SyslogFacility.parse("LOCAL7") == .local7)
    #expect(SyslogFacility.parse(nil) == .local0)
    #expect(SyslogFacility.parse("bogus") == .local0)
    #expect(SyslogTransportKind.parse("udp") == .udp)
    #expect(SyslogTransportKind.parse("") == .tls)
    #expect(SyslogTransportKind.parse(nil) == .tls)
  }

  @Test("Each transport has the port the standard registers")
  func defaultPorts() {
    #expect(SyslogTransportKind.tls.defaultPort == 6514)
    #expect(SyslogTransportKind.tcp.defaultPort == 514)
    #expect(SyslogTransportKind.udp.defaultPort == 514)
    #expect(SyslogDestination(host: "siem.example.com").port == 6514)
    #expect(SyslogDestination(host: "siem.example.com", transport: .udp).port == 514)
    #expect(SyslogDestination(host: "siem.example.com", port: 10514).port == 10514)
  }

  @Test("A literal address is told apart from a name, which decides SNI")
  func literalAddresses() {
    #expect(SyslogDestination(host: "192.0.2.10").hostIsLiteralAddress)
    #expect(SyslogDestination(host: "2001:db8::1").hostIsLiteralAddress)
    #expect(!SyslogDestination(host: "siem.example.com").hostIsLiteralAddress)
  }

  @Test("Blank PEM fields read as absent, and an identity needs both halves")
  func tlsMaterial() {
    let blank = SyslogTLSMaterial(trustedCertificatePEM: "  \n", clientCertificatePEM: "")
    #expect(blank.trustedCertificatePEM == nil)
    #expect(blank.clientCertificatePEM == nil)
    #expect(!blank.hasClientIdentity)
    let half = SyslogTLSMaterial(clientCertificatePEM: "-----BEGIN CERTIFICATE-----")
    #expect(!half.hasClientIdentity)
    let whole = SyslogTLSMaterial(
      clientCertificatePEM: "-----BEGIN CERTIFICATE-----",
      clientPrivateKeyPEM: "-----BEGIN PRIVATE KEY-----")
    #expect(whole.hasClientIdentity)
  }

  @Test("Unreadable PEM is refused as such, not as a connection failure")
  func badPEMIsRefused() async {
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(
        host: "127.0.0.1", port: 1, transport: .tls,
        tls: SyslogTLSMaterial(trustedCertificatePEM: "not a certificate")),
      hostname: "mac")
    await forwarder.export([event])
    await forwarder.settle()
    guard case .failing(let reason) = await forwarder.currentState else {
      Issue.record("expected the forwarder to be failing")
      return
    }
    #expect(reason.contains("certificate") || reason.contains("key"))
    // Still queued: nothing was delivered, and nothing was dropped either.
    #expect(await forwarder.queuedCount == 1)
  }
}
