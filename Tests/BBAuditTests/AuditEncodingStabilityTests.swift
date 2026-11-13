//  AuditEncodingStabilityTests
//  The bytes an audit record is stored, exported and forwarded as, pinned exactly.
//
//  An audit record leaves this Mac: as a row a later build has to read, a CSV someone
//  re-imports, and a syslog body a receiver hashes to deduplicate. All three are written
//  through `JSONValue`'s `Codable` and `AuditJSON`, and a change to either that respells a
//  number or reorders a key is invisible to a structural comparison while breaking every
//  one of those readers. So the expectations here are literal strings, written by the
//  encoder that produced the rows already stored in `app.db`, and a stored row is decoded
//  and written back to prove it comes out byte for byte.
//
//  The metadata covers every case and the spellings that differ between encoders: a whole
//  `Double` (written `2`, read back as `.int`), a `Double` past `Int` (`1e+21`), `Int.max`,
//  a fraction with no short binary form (`0.1`), an escaped quote and newline, an unescaped
//  slash, and non-ASCII text.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBAudit

@Suite("Audit record bytes")
struct AuditEncodingStabilityTests {

  private static let metadata: [String: JSONValue] = [
    "text": .string("a,\"b\"\n/c é 😀"),
    "int": .int(42),
    "negative": .int(-7),
    "max": .int(Int.max),
    "fraction": .double(0.1),
    "half": .double(1.5),
    "whole_double": .double(2.0),
    "huge_double": .double(1e21),
    "flag": .bool(true),
    "nothing": .null,
    "list": .array([.string("x"), .int(1), .double(2.5), .null]),
    "nested": .object(["k": .bool(false), "path": .string("/a/b")]),
    "secret": .redacted,
  ]

  private static let event = AuditEvent(
    kind: .settingsChanged, outcome: .success, actor: .client(address: "203.0.113.9"),
    source: .http, requestID: "req-1", route: "/api/v1/server/settings",
    subject: .setting("example_key"), summary: "Changed, with a \"quote\"",
    metadata: metadata, occurredAt: Date(timeIntervalSince1970: 1_700_000_000.123),
    uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, id: 17)

  /// The `metadata` column exactly as the rows already in `app.db` hold it.
  private static let storedMetadata =
    #"{"flag":true,"fraction":0.1,"half":1.5,"huge_double":1e+21,"int":42,"#
    + #""list":["x",1,2.5,null],"max":9223372036854775807,"negative":-7,"#
    + #""nested":{"k":false,"path":"/a/b"},"nothing":null,"secret":"••••","#
    + #""text":"a,\"b\"\n/c é 😀","whole_double":2}"#

  private static let document =
    #"{"actor":{"id":"203.0.113.9","kind":"client"},"category":"settings","#
    + #""host":"mac.example","id":17,"kind":"settings.changed","metadata":"#
    + storedMetadata
    + #","occurred_at":"2023-11-14T22:13:20.123Z","outcome":"success","#
    + #""request_id":"req-1","route":"/api/v1/server/settings","schema_version":1,"#
    + #""severity":"notice","source":"http","subject":{"id":"example_key","kind":"setting"},"#
    + #""summary":"Changed, with a \"quote\"","uuid":"00000000-0000-4000-8000-000000000001"}"#

  @Test("A new record is stored as the same bytes")
  func rowBytes() throws {
    #expect(try AuditEventRow(Self.event).metadata == Self.storedMetadata)
  }

  @Test("The canonical document is the same bytes")
  func documentBytes() throws {
    let json = try Self.event.json(hostname: "mac.example")
    #expect(String(decoding: json, as: UTF8.self) == Self.document)
  }

  @Test("The CSV line is the same bytes")
  func csvBytes() {
    let quoted = Self.storedMetadata.replacingOccurrences(of: "\"", with: "\"\"")
    let expected =
      "17,00000000-0000-4000-8000-000000000001,2023-11-14T22:13:20.123Z,settings,"
      + "settings.changed,success,notice,client,203.0.113.9,http,req-1,"
      + "/api/v1/server/settings,setting,example_key,\"Changed, with a \"\"quote\"\"\","
      + "\"\(quoted)\"\r\n"
    #expect(AuditCSV.line(for: Self.event) == expected)
  }

  @Test("The syslog message is the same bytes")
  func syslogBytes() {
    let message = SyslogMessage.format(
      Self.event, hostname: "mac.example", processID: 4242, facility: .local0,
      softwareVersion: "1.2.3")
    let expected =
      "<133>1 2023-11-14T22:13:20.123Z mac.example bluebubbles-server 4242 settings "
      + "[origin software=\"bluebubbles-server\" swVersion=\"1.2.3\"] " + Self.document
    #expect(message == expected)
  }

  /// The direction a structural test cannot see: a row written by an earlier build, read by
  /// this one and written again.
  @Test("A stored row decodes, and writes back byte for byte")
  func storedRowRoundTrips() throws {
    var row = try AuditEventRow(Self.event)
    row.metadata = Self.storedMetadata
    let decoded = try row.event()

    // Whole numbers come back as `.int`, a whole double included, because that is the order
    // the stored rows were written to be read in.
    #expect(decoded.metadata["int"] == .int(42))
    #expect(decoded.metadata["max"] == .int(Int.max))
    #expect(decoded.metadata["whole_double"] == .int(2))
    #expect(decoded.metadata["huge_double"] == .double(1e21))
    #expect(decoded.metadata["fraction"] == .double(0.1))
    #expect(decoded.metadata["secret"] == .redacted)

    #expect(try AuditEventRow(decoded).metadata == Self.storedMetadata)
    let json = try decoded.json(hostname: "mac.example")
    #expect(String(decoding: json, as: UTF8.self) == Self.document)
  }

  /// `.int64` is what `JSONValue.parse` produces, so a value that came off the wire can reach
  /// a record; it has to spell the same as `.int`.
  @Test("An int64 encodes as the same digits as an int")
  func int64MatchesInt() throws {
    let wide = try AuditJSON.encode(JSONValue.object(["n": .int64(-9_000_000_000)]))
    let narrow = try AuditJSON.encode(JSONValue.object(["n": .int(-9_000_000_000)]))
    #expect(wide == narrow)
    #expect(String(decoding: wide, as: UTF8.self) == #"{"n":-9000000000}"#)
  }
}
