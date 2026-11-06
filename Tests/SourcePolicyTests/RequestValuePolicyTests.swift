//  RequestValuePolicyTests
//  A request boolean or integer is read through `RequestValues`, never with `.boolValue` or
//  `.intValue` on the raw field.
//
//  `JSONValue.boolValue` and `RequestValues.bool` agree on a JSON body and disagree on a
//  form: a multipart field arrives as the string `"true"`, which `bool` reads as true
//  (`coercingStrings`) and `boolValue` reads as absent, so the route quietly falls back to its
//  default. Eleven handler reads went around the accessor, and a comment above one of them
//  described it as lenient, which it is not. One rule decides what a boolean is; this keeps
//  it the only one.
//
//  `.intValue` on a request field is the same mistake for a number. It answers nil for
//  `"25"` and for `25.0`, both of which the reference's `numeric` rule passes and its
//  routers read with `parseInt`, so `/message/query`, `/chat/query` and `/handle/query`
//  served their default page to a client that had asked for 25 rows. The query parsers in
//  `BBInterfaces` read the body too, so the integer scan covers them as well.

import BBTestCore
import Foundation
import Testing

@Suite("Handlers read booleans and integers through RequestValues")
struct RequestValuePolicyTests {

  static let booleans = PolicyRule(
    rule: "A request boolean is read through `RequestValues`, never with `.boolValue` on the "
      + "raw field, which reads a form's `\"true\"` as absent.",
    fix: "Use `values.bool(_:)`, or `values.truthy(_:)` where the reference coerces with "
      + "`isTruthyBool`.",
    home: #"Sources/BBHandlers/CLAUDE.md, "Reading a request""#)

  static let integers = PolicyRule(
    rule: "A request integer is read through `RequestValues`, never with `.intValue` on the raw "
      + "field, which answers nil for \"25\" and for 25.0.",
    fix: "Use `values.parsedInteger(_:)` or `JSONValue.parsedInteger` where the reference reads "
      + "it with `parseInt`, or `values.int(_:)` where it does not.",
    home: #"Sources/BBHandlers/CLAUDE.md, "Reading a request""#)

  /// Files allowed a `.boolValue`, with the reason. Empty: there is no read that needs one.
  /// A value that is not a request field (a stored record, a helper reply) belongs in the
  /// interface layer rather than here.
  private static let exempt: [String: String] = [:]

  @Test("No handler reads a boolean with `.boolValue`")
  func noRawBooleanReads() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources/BBHandlers", minimum: 11)
    let offences = SourceScanner.offences(in: files) { file, line in
      Self.exempt[file.path] == nil && line.code.contains(".boolValue")
    }
    #expect(offences.isEmpty, Self.booleans.comment(offences))
  }

  /// The shape is a request body's field, `values["limit"]` in a handler or `body["limit"]`
  /// in a query parser, read with `.intValue`. Other `.intValue` reads (a contact id echoed
  /// as a string, a helper reply) are not request numbers and are not matched.
  @Test("No handler or query parser reads a request integer with `.intValue`")
  func noRawIntegerReads() throws {
    let files = try SourceScanner.swiftFiles(
      under: "Sources/BBHandlers", "Sources/BBInterfaces", minimum: 40)
    let rawRead = try Regex(#"\b(values|body)\["[^"]+"\]\??\.intValue"#)
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains(rawRead)
    }
    #expect(offences.isEmpty, Self.integers.comment(offences))
  }
}
