//  RequestValuePolicyTests
//  A handler reads a request boolean through `RequestValues`, never with `.boolValue`.
//
//  `JSONValue.boolValue` and `RequestValues.bool` agree on a JSON body and disagree on a
//  form: a multipart field arrives as the string `"true"`, which `bool` reads as true
//  (`coercingStrings`) and `boolValue` reads as absent, so the route quietly falls back to its
//  default. Eleven handler reads went around the accessor, and a comment above one of them
//  described it as lenient, which it is not. One rule decides what a boolean is; this keeps
//  it the only one.

import BBTestSupport
import Testing

@Suite("Handlers read booleans through RequestValues")
struct RequestValuePolicyTests {

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
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a handler reads a boolean around `RequestValues`; use `values.bool(_:)`, "
          + "or `values.truthy(_:)` where the reference coerces with `isTruthyBool`:\n"
          + offences.report)
    )
  }
}
