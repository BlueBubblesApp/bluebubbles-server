//  RequestValidationTests
//  The accept/reject boundary, pinned against validatorjs rather than against intuition.
//
//  WHAT THIS SUITE IS ACTUALLY FOR
//  Validation is the one change in this project that can only break a client by being too
//  STRICT. A rule that is too lax preserves the behaviour shipped today; a rule that is too
//  strict turns a working request into a 400. So the bulk of this file is not "these bad
//  inputs are refused" — it is **"these surprising inputs are ACCEPTED"**, because each of
//  them is a request a real client may be sending right now and every one of them would be
//  refused by a reasonable-looking reimplementation.
//
//  Each expectation below is traceable to `node_modules/validatorjs/src`, named in the test.
//  Where a test asserts a message string, that string is the contract: a client shows it.

import BBSerialization
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Request validation")
struct RequestValidationTests {

  private func check(
    _ fields: [String: JSONValue], _ rules: [FieldValidation], source: ValidationSource = .body
  ) throws {
    try RequestValidator.validate(.object(fields), against: .init(source, rules))
  }

  /// The refusal sentence, or nil when the input was accepted.
  private func refusal(
    _ fields: [String: JSONValue], _ rules: [FieldValidation], source: ValidationSource = .body
  ) -> String? {
    do {
      try check(fields, rules, source: source)
      return nil
    } catch let error as BadRequest {
      return error.errorMessage
    } catch {
      return "unexpected: \(error)"
    }
  }

  // MARK: - The fixture this layer exists for

  @Test("The recorded 400: a non-numeric limit is refused with the reference's sentence")
  func recordedLimitFixture() {
    // post_api_v1_message_query-5baa61-400.json
    #expect(
      refusal(
        ["limit": .string("not-a-number")], [.init("limit", [.numeric, .min(1), .max(1000)])])
        == "The limit must be a number.")
  }

  @Test("The recorded 400: a missing required `after` on count/updated")
  func recordedAfterFixture() {
    // get_api_v1_message_count_updated-5baa61-400.json
    #expect(
      refusal([:], [.init("after", [.required, .numeric, .min(0)])], source: .query)
        == "The after field is required.")
  }

  // MARK: - Accepted, and each one would break a client if it were not
  //
  // `rules.js` and `validator.js:_isValidatable`.

  @Test("A number sent as a string passes `numeric` — the single most important case here")
  func numberAsStringIsAccepted() {
    // `numeric` is `Number(val)` coercion, not a type check. Real clients send `"100"`, and
    // `RequestValues`' whole leniency design exists because of it.
    for limit in ["100", "1", "1000", "25.0", "1e2", " 50 "] {
      #expect(
        refusal(["limit": .string(limit)], [.init("limit", [.numeric, .min(1), .max(1000)])])
          == nil, "\(limit) should be accepted")
    }
  }

  @Test("An empty string satisfies every non-implicit rule, because none of them run")
  func emptyStringIsNeverValidated() {
    // `_isValidatable` skips a non-implicit rule unless the value would pass `required`.
    // `""` does not, so `numeric`, `string`, `in` and `min` are all skipped. This is why
    // `{"limit": ""}` is a 200 in the reference and must stay one here.
    #expect(refusal(["limit": .string("")], [.init("limit", [.numeric, .min(1)])]) == nil)
    #expect(refusal(["sort": .string("")], [.init("sort", [.string, .inList(["ASC"])])]) == nil)
    #expect(refusal(["limit": .string("   ")], [.init("limit", [.numeric, .min(1)])]) == nil)
  }

  @Test("An absent field satisfies every non-implicit rule")
  func absentFieldIsNeverValidated() {
    #expect(refusal([:], [.init("limit", [.numeric, .min(1), .max(1000)])]) == nil)
    #expect(refusal([:], [.init("sort", [.string, .inList(["ASC", "DESC"])])]) == nil)
  }

  @Test("An explicit null satisfies every non-implicit rule, and `present`")
  func nullIsLenient() {
    #expect(refusal(["limit": .null], [.init("limit", [.numeric])]) == nil)
    // `present` is `typeof val !== "undefined"`, which null satisfies.
    #expect(refusal(["message": .null], [.init("message", [.present, .string])]) == nil)
    // ...but `required` is not satisfied by null.
    #expect(
      refusal(["chatGuid": .null], [.init("chatGuid", [.required, .string])])
        == "The chatGuid field is required.")
  }

  @Test("A falsy value passes `in`, however invalid it looks")
  func falsyPassesInList() {
    // `rules.js:in` opens with `if (val)`, so 0, "" and false skip the membership check.
    #expect(refusal(["sort": .int(0)], [.init("sort", [.inList(["ASC", "DESC"])])]) == nil)
    #expect(refusal(["sort": .bool(false)], [.init("sort", [.inList(["ASC", "DESC"])])]) == nil)
  }

  @Test("`0` and `false` pass `required`; an empty array does not")
  func requiredUsesStringCoercion() {
    // `String(0)` is "0" and `String(false)` is "false", both non-empty. `String([])` is "",
    // which is the surprise: an empty array is the one falsy-looking value `required` refuses.
    #expect(refusal(["partIndex": .int(0)], [.init("partIndex", [.required])]) == nil)
    #expect(refusal(["ddScan": .bool(false)], [.init("ddScan", [.required])]) == nil)
    #expect(
      refusal(["ids": .array([])], [.init("ids", [.required, .array])])
        == "The ids field is required.")
    #expect(refusal(["ids": .array([.int(1)])], [.init("ids", [.required, .array])]) == nil)
  }

  @Test("`boolean` accepts the eight spellings the reference accepts, and no others")
  func booleanSpellings() {
    for value in [
      JSONValue.bool(true), .bool(false), .int(0), .int(1),
      .string("0"), .string("1"), .string("true"), .string("false"),
    ] {
      #expect(refusal(["force": value], [.init("force", [.boolean])]) == nil, "\(value)")
    }
    // Not accepted: a different casing, or a word that means the same thing.
    #expect(refusal(["force": .string("True")], [.init("force", [.boolean])]) != nil)
    #expect(refusal(["force": .string("yes")], [.init("force", [.boolean])]) != nil)
  }

  @Test("A boolean is refused by `numeric` even though it coerces to a number")
  func booleanIsNotNumeric() {
    // `typeof val !== "boolean"` is an explicit carve-out; `Number(true)` is 1.
    #expect(
      refusal(["limit": .bool(true)], [.init("limit", [.numeric])])
        == "The limit must be a number.")
  }

  // MARK: - Refused, matching the reference

  @Test("A wrong-typed field is refused with the rule's own sentence")
  func wrongTypesAreRefused() {
    #expect(
      refusal(["chatGuid": .int(5)], [.init("chatGuid", [.string])])
        == "The chatGuid must be a string.")
    #expect(
      refusal(["sort": .string("SIDEWAYS")], [.init("sort", [.string, .inList(["ASC", "DESC"])])])
        == "The selected sort is invalid.")
    #expect(
      refusal(["with": .string("x")], [.init("with", [.array])])
        == "The with attribute has errors.")
    #expect(
      refusal(["payload": .string("x")], [.init("payload", [.jsonObject])])
        == "The payload must be a valid json object.")
  }

  @Test("`min` and `max` measure a number for a numeric field and characters otherwise")
  func sizeHasThreeMeanings() {
    // Numeric field: the value itself, and the message has no "characters".
    #expect(
      refusal(["limit": .int(0)], [.init("limit", [.numeric, .min(1)])])
        == "The limit must be at least 1.")
    #expect(
      refusal(["limit": .int(5000)], [.init("limit", [.numeric, .min(1), .max(1000)])])
        == "The limit may not be greater than 1000.")
    // Non-numeric field: the character count, and the message says so.
    #expect(
      refusal(["name": .string("ab")], [.init("name", [.required, .string, .min(3), .max(50)])])
        == "The name must be at least 3 characters.")
    #expect(
      refusal(
        ["name": .string(String(repeating: "a", count: 51))],
        [.init("name", [.required, .string, .min(3), .max(50)])])
        == "The name may not be greater than 50 characters.")
  }

  @Test("A numeric string is measured as its number, not its length")
  func numericStringMeasuresAsNumber() {
    // `getSize` uses parseFloat when the field has a numeric rule, so "5000" is 5000 and not
    // 4. Getting this wrong would accept an over-large limit sent as a string.
    #expect(
      refusal(["limit": .string("5000")], [.init("limit", [.numeric, .min(1), .max(1000)])])
        == "The limit may not be greater than 1000.")
    #expect(refusal(["limit": .string("999")], [.init("limit", [.numeric, .max(1000)])]) == nil)
  }

  // MARK: - Order

  @Test("The first failure wins, in field order then rule order")
  func firstErrorOnly() {
    // Two fields both fail; the earlier-declared one is reported.
    let rules: [FieldValidation] = [
      .init("chatGuid", [.required, .string]),
      .init("limit", [.numeric]),
    ]
    #expect(refusal(["limit": .string("nope")], rules) == "The chatGuid field is required.")

    // Within a field, the earlier rule is reported: `string` before `in`.
    #expect(
      refusal(["sort": .int(7)], [.init("sort", [.string, .inList(["ASC"])])])
        == "The sort must be a string.")
  }

  @Test("`address: string|required` reports the string failure, not the required one")
  func ruleOrderIsTranscribedNotNormalised() {
    // The availability routes declare their rules in this order and no other rule set does.
    // A tidy-up that sorted them would change the sentence a client is shown.
    #expect(
      refusal(["address": .int(1)], [.init("address", [.string, .required])], source: .query)
        == "The address must be a string.")
  }

  // MARK: - Wildcards

  @Test("`where.*.statement` is checked per element and names the index")
  func wildcardExpansion() {
    let rules: [FieldValidation] = [
      .init("where", [.array]),
      .init("where.*.statement", [.required, .string]),
      .init("where.*.args", [.present]),
    ]

    // Well-formed: accepted.
    #expect(
      refusal(
        [
          "where": .array([
            .object(["statement": .string("message.rowid > ?"), "args": .int(5)])
          ])
        ], rules) == nil)

    // Second element missing its statement: the attribute names the index.
    #expect(
      refusal(
        [
          "where": .array([
            .object(["statement": .string("a"), "args": .null]),
            .object(["args": .int(1)]),
          ])
        ], rules) == "The where.1.statement field is required.")
  }

  @Test("A wildcard whose parent is absent or not an array expands to nothing")
  func wildcardWithoutParent() {
    let rules: [FieldValidation] = [.init("where.*.statement", [.required, .string])]
    #expect(refusal([:], rules) == nil)
    #expect(refusal(["where": .string("x")], rules) == nil)
    #expect(refusal(["where": .array([])], rules) == nil)
  }

  @Test("`args` may be null but may not be omitted")
  func presentOnWildcardArgs() {
    let rules: [FieldValidation] = [.init("where.*.args", [.present])]
    #expect(refusal(["where": .array([.object(["args": .null])])], rules) == nil)
    #expect(
      refusal(["where": .array([.object(["statement": .string("a")])])], rules)
        == "The where.0.args field must be present (but can be empty).")
  }

  // MARK: - Sources

  @Test("Query and path values are strings, and coerce the way the reference's do")
  func queryValuesAreStrings() {
    // `?after=5` is the string "5": it must pass `numeric` and measure as 5 under `min`.
    #expect(
      refusal(
        ["after": .string("5")], [.init("after", [.required, .numeric, .min(0)])],
        source: .query) == nil)
    #expect(
      refusal(
        ["after": .string("-1")], [.init("after", [.required, .numeric, .min(0)])],
        source: .query) == "The after must be at least 0.")
  }

  @Test("A body that is not an object validates as an empty one")
  func nonObjectBody() throws {
    // validatorjs flattens a non-object to no attributes, so only implicit rules can fail.
    let rules = ValidationRuleSet(.body, [.init("chatGuid", [.required, .string])])
    #expect(throws: BadRequest.self) {
      try RequestValidator.validate(.array([.int(1)]), against: rules)
    }
    #expect(throws: Never.self) {
      try RequestValidator.validate(
        .array([.int(1)]), against: .init(.body, [.init("limit", [.numeric])]))
    }
  }
}
