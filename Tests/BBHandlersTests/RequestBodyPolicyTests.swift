//  RequestBodyPolicyTests
//  A handler never swallows a body it could not read.
//
//  `(try? request.jsonBody()) ?? nil` turns "this is not JSON" into "there was no body", so a
//  client typo runs the route with every argument defaulted and gets a 200 for it. Three
//  routes did exactly that: `POST facetime/link` minted a link with nobody invited, `DELETE
//  facetime/link` invalidated every link instead of the ones named, and the backup deletes
//  fell back to a query parameter. `request.values()` is the one way to read a body; it
//  keeps an absent body lenient and lets a malformed one fail, and this test refuses the
//  alternative the same way `SettingKeyLiteralTests` refuses a literal key.

import BBTestSupport
import Testing

@Suite("Handlers do not swallow an unreadable body")
struct RequestBodyPolicyTests {

  @Test("No handler reads a request with `try?`")
  func noOptionalTryOnRequests() throws {
    let pattern = try Regex(#"try\?\s+(await\s+)?request\."#)
    let files = try SourceScanner.swiftFiles(under: "Sources/BBHandlers", minimum: 11)
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a handler swallows a body it could not read; use `try request.values()`:\n"
          + offences.report)
    )
  }

  /// A list read with `compactMap(\.stringValue)` drops what it cannot read: a value that is
  /// not a list becomes nil, and nil means "all of them" on more than one route. Read lists
  /// with `RequestValues.strings`, which refuses instead. The one left is a v1 route whose
  /// reference drops the same elements.
  @Test("No handler shortens a list it could not read")
  func noDroppedListElements() throws {
    let contactQuery =
      "`extraProperties` on `POST /contact/query` is v1, and the reference reads it with "
      + "`parseWithQuery`, which keeps only the string elements of a list "
      + "(`filter((e: any) => typeof e === \"string\")`, v1/utils.ts)."
    let exempt = ["Sources/BBHandlers/ReadHandlers.swift": contactQuery]
    let files = try SourceScanner.swiftFiles(under: "Sources/BBHandlers", minimum: 11)
    let offences = SourceScanner.offences(in: files) { file, line in
      exempt[file.path] == nil && line.code.contains("arrayValue?.compactMap(\\.stringValue)")
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a handler drops list elements it could not read; use `values.strings`:\n"
          + offences.report)
    )
  }
}
