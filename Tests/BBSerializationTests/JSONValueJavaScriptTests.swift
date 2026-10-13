//  JSONValueJavaScriptTests
//  Truthiness and "is a number" as the reference's JavaScript answers them, because the
//  request validators and the scheduling rules both branch on these answers.

import BBCore
import BBSerialization
import Testing

@Suite("JSONValue in JavaScript's terms")
struct JSONValueJavaScriptTests {

  @Test("Falsy is false, zero, NaN, the empty string, null and undefined")
  func falsy() {
    let falsy: [JSONValue?] = [
      nil, .null, .bool(false), .int(0), .int64(0), .double(0), .double(.nan), .string(""),
    ]
    for value in falsy {
      #expect(!value.isTruthy, "\(String(describing: value))")
    }
  }

  @Test("Everything else is truthy, an empty array or object included")
  func truthy() {
    let truthy: [JSONValue] = [
      .bool(true), .int(-1), .int64(1), .double(0.5), .string("0"), .string("false"),
      .array([]), .object([:]),
    ]
    for value in truthy {
      #expect(value.isTruthy, "\(value)")
    }
  }

  @Test("A number is a number in any of its three cases, and a numeric string is not one")
  func numbers() {
    #expect(JSONValue.int(3600).numberValue == 3600)
    #expect(JSONValue.int64(3600).numberValue == 3600)
    #expect(JSONValue.double(3600.5).numberValue == 3600.5)
    #expect(JSONValue.string("3600").numberValue == nil)
    #expect(JSONValue.bool(true).numberValue == nil)
    #expect(JSONValue.null.numberValue == nil)
  }
}
