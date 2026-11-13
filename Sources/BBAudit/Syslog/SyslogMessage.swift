//  SyslogMessage
//  An audit record as an RFC 5424 syslog message.
//
//  The layout is the standard's, exactly, because the whole point of forwarding to a SIEM is
//  that the receiver already knows how to read it:
//
//      <PRI>1 TIMESTAMP HOSTNAME APP-NAME PROCID MSGID STRUCTURED-DATA MSG
//
//  Three decisions worth stating:
//
//    - **`MSGID` is the CATEGORY, not the kind.** The field is capped at 32 characters and
//      several kinds are longer; the category is short, stable and what a receiver routes on.
//      The kind is in the body.
//    - **The body is the record's JSON document, whole.** Receivers extract fields from a
//      JSON body with their standard tooling, and a Postgres table fed by one can query the
//      document with the JSON operators. A key-value rendering would be a second format to
//      document and to keep in step.
//    - **Structured data carries only the `origin` element**, which the standard defines:
//      the software and its version. Every other field lives in the body. A private SD-ID
//      needs an enterprise number this project does not have, and the one reserved for
//      documentation is not ours to ship.
//
//  The body carries no byte-order mark. The standard permits one and several receivers
//  mishandle it, and a receiver that needs it can be told the encoding instead.
//
//  See `docs/AUDIT_LOG.md`.

import BBCore
import Foundation

/// The facility code a receiver files these under. `local0` by default: the range the
/// standard sets aside for a site's own use, and the one every receiver's default rules pass.
public enum SyslogFacility: String, Sendable, Hashable, CaseIterable {
  case local0, local1, local2, local3, local4, local5, local6, local7
  case user
  case daemon
  case auth
  case authpriv

  public var code: Int {
    switch self {
    case .user: 1
    case .daemon: 3
    case .auth: 4
    case .authpriv: 10
    case .local0: 16
    case .local1: 17
    case .local2: 18
    case .local3: 19
    case .local4: 20
    case .local5: 21
    case .local6: 22
    case .local7: 23
    }
  }

  /// The facility a stored field names, or `local0` for anything else.
  public static func parse(_ stored: String?) -> SyslogFacility {
    stored.flatMap { SyslogFacility(rawValue: $0.lowercased()) } ?? .local0
  }
}

/// How messages reach the receiver.
public enum SyslogTransportKind: String, Sendable, Hashable, CaseIterable {
  /// RFC 5425: TLS over TCP, octet-counted frames. The default, and the only one of the three
  /// a record should cross a network boundary on.
  case tls
  /// RFC 6587: plain TCP, octet-counted frames.
  case tcp
  /// RFC 5426: one datagram per message, no framing and no delivery guarantee.
  case udp

  /// The port the standard registers for the transport, when the operator names none.
  public var defaultPort: Int {
    switch self {
    case .tls: 6514
    case .tcp, .udp: 514
    }
  }

  public static func parse(_ stored: String?) -> SyslogTransportKind {
    stored.flatMap { SyslogTransportKind(rawValue: $0.lowercased()) } ?? .tls
  }
}

public enum SyslogMessage {

  /// `APP-NAME`. Fixed, so a receiver's rule can name it.
  public static let appName = "bluebubbles-server"
  /// The standard's spelling of "no value".
  public static let nilValue = "-"
  /// The standard's cap on `MSGID`.
  static let messageIDLimit = 32
  /// The standard's cap on `HOSTNAME`.
  static let hostnameLimit = 255

  /// `<PRI>`: facility times eight plus severity.
  public static func priority(facility: SyslogFacility, severity: AuditSeverity) -> Int {
    facility.code * 8 + severity.syslogCode
  }

  /// The whole message, without transport framing.
  ///
  /// - Parameters:
  ///   - hostname: This Mac's name. Sanitised to what the header allows.
  ///   - processID: This process, so a receiver can tell two servers on one host apart.
  ///   - softwareVersion: Goes in the `origin` element; nil leaves the element out.
  /// The most a UDP message may carry, in bytes.
  ///
  /// macOS refuses a datagram past `net.inet.udp.maxdgram`, 9,216 by default, and refuses it
  /// every time: a record over that was retried for ever at the head of the queue, and every
  /// record behind it waited until a restart. 8,192 sits under that ceiling, and it is the
  /// size RFC 5425 says a receiver SHOULD accept. TCP and TLS frames carry their length and
  /// have no such ceiling, so they are not cut.
  public static let datagramLimit = 8_192

  public static func format(
    _ event: AuditEvent,
    hostname: String,
    processID: Int32,
    facility: SyslogFacility,
    softwareVersion: String?,
    maximumBytes: Int? = nil
  ) -> String {
    let header = [
      "<\(priority(facility: facility, severity: event.severity))>1",
      AuditTimestamp.string(from: event.occurredAt),
      headerToken(hostname, limit: hostnameLimit),
      appName,
      String(processID),
      headerToken(event.category.rawValue, limit: messageIDLimit),
    ].joined(separator: " ")

    let structuredData: String
    if let softwareVersion {
      structuredData =
        "[origin software=\"\(parameterValue(appName))\" "
        + "swVersion=\"\(parameterValue(softwareVersion))\"]"
    } else {
      structuredData = nilValue
    }

    let prefix = "\(header) \(structuredData) "
    let body = String(
      decoding: (try? event.json(hostname: hostname)) ?? Data("{}".utf8), as: UTF8.self)
    let whole = prefix + body
    guard let maximumBytes, whole.utf8.count > maximumBytes else { return whole }
    return prefix
      + fittedBody(
        event, hostname: hostname, budget: maximumBytes - prefix.utf8.count,
        originalBytes: whole.utf8.count)
  }

  /// The record's document cut to `budget` bytes, still valid JSON.
  ///
  /// The envelope always survives (uuid, time, kind, actor, outcome), so the receiver's copy
  /// still joins the local one, which keeps the record whole. The kind-specific `metadata` is
  /// what grows without bound, a settings change carrying a long value, so it goes first and
  /// a marker says how large the record was. Only if that is not enough is the summary cut.
  static func fittedBody(
    _ event: AuditEvent, hostname: String, budget: Int, originalBytes: Int
  ) -> String {
    var document = event.document(hostname: hostname)
    document["metadata"] = .object([
      "truncated": .bool(true), "original_bytes": .int(originalBytes),
    ])
    func encoded() -> String {
      String(
        decoding: (try? AuditJSON.encode(JSONValue.object(document))) ?? Data("{}".utf8),
        as: UTF8.self)
    }
    var body = encoded()
    var summary = event.summary
    // Escaping can make the encoded summary longer than the text, so this shrinks until the
    // whole body fits rather than trusting one subtraction.
    while body.utf8.count > budget, !summary.isEmpty {
      let overflow = body.utf8.count - budget
      summary = utf8Prefix(summary, bytes: max(0, summary.utf8.count - overflow - 3))
      document["summary"] = .string(summary + "…")
      body = encoded()
    }
    return body
  }

  /// The longest prefix of `text` that is at most `bytes` in UTF-8, cut between characters.
  static func utf8Prefix(_ text: String, bytes: Int) -> String {
    var used = 0
    var end = text.startIndex
    for character in text {
      let size = character.utf8.count
      guard used + size <= bytes else { break }
      used += size
      end = text.index(after: end)
    }
    return String(text[..<end])
  }

  /// RFC 6587 octet counting: the message's byte length, a space, the message.
  ///
  /// The framing TCP and TLS use. Non-transparent framing (a trailing newline) is the
  /// alternative the standard allows, and a JSON body can hold a newline inside a string,
  /// which is exactly the byte that framing cannot survive.
  public static func octetCountedFrame(_ message: String) -> String {
    "\(message.utf8.count) \(message)"
  }

  /// A header field: printable ASCII with no spaces, cut to the standard's limit, and `-`
  /// when nothing is left.
  static func headerToken(_ raw: String, limit: Int) -> String {
    var token = ""
    for scalar in raw.unicodeScalars where scalar.value > 32 && scalar.value < 127 {
      token.unicodeScalars.append(scalar)
      if token.unicodeScalars.count == limit { break }
    }
    return token.isEmpty ? nilValue : token
  }

  /// An SD-PARAM value: the three characters the standard escapes, escaped.
  static func parameterValue(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "]", with: "\\]")
  }
}
