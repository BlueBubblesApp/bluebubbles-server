//  WireProtocolTests
//  The legacy helper protocol's decoding rules.
//
//  These look like trivia and are not. `readTransactionData` in the current server has three
//  distinct outcomes depending on which keys are present, and callers branch on which of them
//  they got. Reproducing it approximately would break the shipped helper in ways that only
//  show up for particular actions.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBPrivateAPI

private func decode(_ json: String) throws -> HelperResponse {
  try JSONDecoder().decode(HelperResponse.self, from: Data(json.utf8))
}

@Suite("Helper response decoding")
struct HelperResponseTests {

  /// Rule 1: a non-empty `data` key wins outright.
  @Test("A non-empty data key is the result")
  func dataKeyWins() throws {
    let response = try decode(
      #"{"transactionId":"t1","data":{"path":"/tmp/a.png"},"identifier":"ignored"}"#)
    #expect(response.transactionId == "t1")
    #expect(response.result?["path"]?.stringValue == "/tmp/a.png")
  }

  /// Rule 2: with no usable `data`, the reserved keys are stripped and the REMAINDER is the
  /// payload. This is how most actions actually answer.
  @Test("Without data, the remainder minus reserved keys is the result")
  func remainderIsResult() throws {
    let response = try decode(
      #"{"transactionId":"t1","identifier":"abc","error":"","typing":true}"#)
    #expect(response.result?["typing"]?.boolValue == true)
    // The reserved keys must not leak into the payload.
    #expect(response.result?["transactionId"] == nil)
    #expect(response.result?["identifier"] == nil)
    #expect(response.result?["error"] == nil)
  }

  /// Rule 3: nothing left after stripping means nil, NOT an empty object. Callers check for
  /// nil to decide whether an action returned anything.
  @Test("An empty remainder is nil, not an empty object")
  func emptyRemainderIsNil() throws {
    let response = try decode(#"{"transactionId":"t1","identifier":"abc"}"#)
    #expect(response.result == nil)
  }

  /// The helper sends `"error": ""` on success, so presence of the key is not failure —
  /// only a non-empty value is. Getting this backwards fails every successful call.
  @Test("An empty error string is success, not failure")
  func emptyErrorIsSuccess() throws {
    #expect(try decode(#"{"transactionId":"t1","error":""}"#).failureReason == nil)
    #expect(try decode(#"{"transactionId":"t1","error":"nope"}"#).failureReason == "nope")
    #expect(try decode(#"{"transactionId":"t1"}"#).failureReason == nil)
  }

  /// An event frame carries no transaction id and is dispatched rather than correlated.
  @Test("An event frame is distinguished by having no transaction id")
  func eventFrame() throws {
    let response = try decode(
      #"{"event":"started-typing","chatGuid":"iMessage;-;someone@example.com"}"#)
    #expect(response.transactionId == nil)
    #expect(response.event == "started-typing")
    #expect(response.remainder["chatGuid"]?.stringValue == "iMessage;-;someone@example.com")
  }
}

@Suite("Wire JSON")
struct WireJSONTests {

  /// The helper is Objective-C and answers with 0/1 as readily as with true/false. A client
  /// that only accepts booleans reads every numeric answer as false.
  @Test("Numbers and booleans are both accepted as truth values")
  func numericBooleans() {
    #expect(WireJSON.bool(true).boolValue == true)
    #expect(WireJSON.number(1).boolValue == true)
    #expect(WireJSON.number(0).boolValue == false)
  }

  /// Whole numbers must not go out as `0.0`. This protocol has been bitten by that before —
  /// `partIndex` is compared as a string on the far side.
  @Test("Whole numbers encode as integers, not as decimals")
  func wholeNumbersEncodeAsIntegers() throws {
    let encoded = try JSONEncoder().encode(WireJSON.object(["partIndex": .number(0)]))
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(text.contains("\"partIndex\":0"))
    #expect(!text.contains("0.0"))
  }

  @Test("Fractional numbers keep their fraction")
  func fractionsSurvive() throws {
    let encoded = try JSONEncoder().encode(WireJSON.object(["latitude": .number(37.5)]))
    #expect(String(decoding: encoded, as: UTF8.self).contains("37.5"))
  }

  /// The helper branches on key PRESENCE for several optional fields, so a nil must be
  /// omitted rather than written as null.
  @Test("Dropping construction omits nil keys rather than nulling them")
  func droppingOmitsNil() throws {
    let payload = WireJSON.object(dropping: [
      "chatGuid": .string("iMessage;-;someone@example.com"),
      "subject": nil,
      "effectId": nil,
    ])
    let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    #expect(text.contains("chatGuid"))
    #expect(!text.contains("subject"))
    #expect(!text.contains("null"))
  }

  @Test("Round trips preserve structure")
  func roundTrip() throws {
    let original = WireJSON.object([
      "list": .array([.string("a"), .number(2), .bool(false), .null]),
      "nested": .object(["k": .string("v")]),
    ])
    let decoded = try JSONDecoder().decode(
      WireJSON.self, from: try JSONEncoder().encode(original)
    )
    #expect(decoded == original)
  }
}

@Suite("Request encoding")
struct HelperRequestTests {

  /// `{"action":…,"data":{…},"transactionId":…}` — the exact envelope the shipped helper
  /// parses.
  @Test("A request carries action, data and transaction id")
  func envelopeShape() throws {
    let request = HelperRequest(
      action: "send-message",
      data: .object(["chatGuid": .string("iMessage;-;someone@example.com")]),
      transactionId: "abc"
    )
    let object =
      try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(request)
      ) as? [String: Any]

    #expect(object?["action"] as? String == "send-message")
    #expect(object?["transactionId"] as? String == "abc")
    #expect(
      (object?["data"] as? [String: Any])?["chatGuid"] as? String
        == "iMessage;-;someone@example.com")
  }

  /// A fire-and-forget action has no transaction id at all — the key is absent rather than
  /// null, because the helper checks for its presence.
  @Test("A request without a transaction omits the key")
  func absentTransactionId() throws {
    let encoded = try JSONEncoder().encode(
      HelperRequest(action: "start-typing", data: .object([:]), transactionId: nil)
    )
    #expect(!String(decoding: encoded, as: UTF8.self).contains("transactionId"))
  }
}
