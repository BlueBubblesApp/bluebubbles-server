//  DirectJSONEncoderTests
//  The wire encoder, against the `JSONSerialization` path it replaced.
//
//  `serialize()` used to build `foundationObject` first -- a complete second tree of boxed
//  `NSNumber`, `NSString` and `NSDictionary`, built so it could be walked once and discarded.
//  Four representations of one response coexisted at peak: the rows, the `JSONValue` tree,
//  the Foundation tree, and the output `Data`.
//
//  Replacing an encoder is the change most able to break a frozen wire quietly, so this
//  compares the two paths by PARSING both and requiring the same value back, rather than by
//  comparing bytes -- key order in a `[String: JSONValue]` is arbitrary and always has been.
//  The two places the bytes deliberately differ are asserted directly, and both move toward
//  the reference server rather than away from it.

import Foundation
import Testing

@testable import BBSerialization

@Suite("Direct JSON encoder")
struct DirectJSONEncoderTests {

  /// Both paths, parsed back, must be the same value.
  private func expectAgrees(_ value: JSONValue, _ comment: Comment) throws {
    let direct = try value.serialize()
    let viaFoundation = try JSONSerialization.data(
      withJSONObject: value.foundationObject, options: [])
    let a = try JSONValue.parse(direct)
    let b = try JSONValue.parse(viaFoundation)
    #expect(a == b, comment)
    // NOT compared against `value`: `parse` returns `.int64` for every integer, whichever
    // encoder produced the bytes, so an input built with `.int` can never come back equal.
    // That is the parser's long-standing behaviour and has nothing to do with this change.
  }

  @Test("Scalars agree with the Foundation path")
  func scalarsAgree() throws {
    try expectAgrees(.object(["v": .null]), "null")
    try expectAgrees(.object(["v": .bool(true)]), "true")
    try expectAgrees(.object(["v": .bool(false)]), "false")
    try expectAgrees(.object(["v": .int(0)]), "zero")
    try expectAgrees(.object(["v": .int(-42)]), "negative")
    try expectAgrees(.object(["v": .int64(Int64.max)]), "int64 max")
    try expectAgrees(.object(["v": .int64(Int64.min)]), "int64 min")
    try expectAgrees(.object(["v": .string("")]), "empty string")
  }

  /// Every escape the format has, plus the ones it deliberately does not apply.
  @Test("Strings are escaped the same way")
  func stringsAgree() throws {
    let awkward = [
      "quote\" here",
      "back\\slash",
      "slash/not/escaped",
      "tab\there",
      "newline\nhere",
      "carriage\rreturn",
      "form\u{0C}feed",
      "back\u{08}space",
      "control\u{01}\u{1F}chars",
      "delete\u{7F}kept",
      "emoji 😀 and accents éàü",
      "line\u{2028}separator",
      "nul\u{00}byte",
    ]
    for value in awkward {
      try expectAgrees(.object(["v": .string(value)]), "\(value.debugDescription)")
    }
  }

  @Test("Containers agree, including empty and nested ones")
  func containersAgree() throws {
    try expectAgrees(.array([]), "empty array")
    try expectAgrees(.object([:]), "empty object")
    try expectAgrees(.array([.int(1), .string("two"), .null, .bool(false)]), "mixed array")
    try expectAgrees(
      .object([
        "a": .array([.object(["b": .array([.int(1)])])]),
        "c": .object(["d": .object([:])]),
      ]), "nested")
  }

  /// Doubles parse back to the same value, which is the property that matters. The BYTES
  /// differ on purpose; see the two tests below.
  @Test("Doubles parse back to the same value")
  func doublesRoundTrip() throws {
    let values: [Double] = [
      0, 1, -1, 0.1, 1.5, -2.25, 1e-20, 1e20, 1.0 / 3.0, 123456789.123456789,
      -0.0, 2.2250738585072014e-308, Double(Int64.max),
    ]
    for value in values {
      let data = try JSONValue.object(["v": .double(value)]).serialize()
      guard case .object(let parsed)? = try? JSONValue.parse(data) else {
        Issue.record("\(value) did not parse back as an object")
        continue
      }
      switch parsed["v"] {
      case .double(let back): #expect(back == value, "\(value) came back as \(back)")
      // An integral double is written as an integer, and parses back as one.
      case .int64(let back): #expect(Double(back) == value, "\(value) came back as \(back)")
      case .int(let back): #expect(Double(back) == value, "\(value) came back as \(back)")
      default: Issue.record("\(value) came back as \(String(describing: parsed["v"]))")
      }
    }
  }

  /// The first deliberate difference. Every double this server has ever sent differed from
  /// the reference server, which emits the shortest form that round-trips -- `JSON.stringify`
  /// and Swift's `description` use the same algorithm. `JSONSerialization` wrote
  /// seventeen significant digits.
  @Test("A double is written the way the reference server writes it")
  func doublesMatchTheReference() throws {
    let data = try JSONValue.object(["v": .double(0.1)]).serialize()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text == "{\"v\":0.1}", "\(text)")

    let old = try JSONSerialization.data(
      withJSONObject: JSONValue.object(["v": .double(0.1)]).foundationObject, options: [])
    // Non-vacuity: the path this replaced really did write something else.
    #expect(String(decoding: old, as: UTF8.self) != text)
  }

  @Test("An integral double keeps its integer spelling")
  func integralDoublesHaveNoFraction() throws {
    #expect(String(decoding: try JSONValue.double(1).serialize(), as: UTF8.self) == "1")
    #expect(String(decoding: try JSONValue.double(-0.0).serialize(), as: UTF8.self) == "0")
    #expect(String(decoding: try JSONValue.double(-7).serialize(), as: UTF8.self) == "-7")
  }

  /// The second deliberate difference, and a crash that used to be reachable from a
  /// response: `JSONSerialization` raises an Objective-C exception for a non-finite double,
  /// which Swift cannot catch, so the process died rather than the request failing.
  @Test("A non-finite double throws instead of terminating the process")
  func nonFiniteThrows() {
    for value in [Double.nan, .infinity, -.infinity] {
      #expect(throws: JSONValue.EncodingError.self) {
        _ = try JSONValue.object(["v": .double(value)]).serialize()
      }
    }
  }

  /// A realistic payload, end to end.
  @Test("A message-shaped payload agrees with the Foundation path")
  func realisticPayloadAgrees() throws {
    let payload = JSONValue.object([
      "status": .int(200),
      "message": .string("Success"),
      "data": .array([
        .object([
          "guid": .string("p:0/11111111-2222-3333-4444-555555555555"),
          "text": .string("Hey there — \"quoted\", with a\ttab"),
          "dateCreated": .int64(1_678_307_200_000),
          "isFromMe": .bool(true),
          "handle": .null,
          "attachments": .array([]),
          "latitude": .double(37.7749),
          "chats": .array([.object(["guid": .string("any;-;someone@example.com")])]),
        ])
      ]),
    ])
    try expectAgrees(payload, "message payload")
  }
}
