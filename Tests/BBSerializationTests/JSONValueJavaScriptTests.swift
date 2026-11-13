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

  /// `Number.parseInt(x, 10)`, each expectation what Node answers for the same input
  /// (checked by running `Number.parseInt(v, 10)` on each).
  @Test(
    "parseInt reads a number, a fraction and a numeric string as the reference does",
    arguments: [
      (JSONValue.int(25), 25), (.int64(25), 25), (.double(25), 25), (.double(25.7), 25),
      (.double(-25.7), -25), (.string("25"), 25), (.string("  25"), 25), (.string("+7"), 7),
      (.string("-7"), -7), (.string("25.9"), 25), (.string("12abc"), 12), (.string("1e3"), 1),
      (.string("007"), 7), (.double(1e21), 1), (.double(2.5e-7), 2), (.double(0), 0),
    ])
  func parsedInteger(value: JSONValue, expected: Int) {
    #expect(value.parsedInteger == expected)
  }

  @Test(
    "parseInt answers NaN, read as nil, for what has no leading digits",
    arguments: [
      JSONValue.string(""), .string("abc"), .string("-"), .string("x10"),
      .bool(true), .null, .object([:]), .double(.nan), .double(.infinity),
    ])
  func parsedIntegerIsNaN(value: JSONValue) {
    #expect(value.parsedInteger == nil)
  }

  /// The one place this departs from Node, which answers `parseInt([1], 10) === 1` through
  /// `String([1])`. Pinned so the departure is a decision rather than an accident.
  @Test("An array is not read as a number, although parseInt would read [1] as 1")
  func parsedIntegerOfAnArray() {
    #expect(JSONValue.array([.int(1)]).parsedInteger == nil)
  }
}
