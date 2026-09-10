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

import Foundation
import Testing

@Suite("Handlers do not swallow an unreadable body")
struct RequestBodyPolicyTests {

  @Test("No handler reads a request with `try?`")
  func noOptionalTryOnRequests() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BBHandlers")
    let pattern = try Regex(#"try\?\s+(await\s+)?request\."#)

    var offenders: [String] = []
    var scanned = 0
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      scanned += 1
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        if code.contains(pattern) {
          offenders.append("Sources/BBHandlers/\(relative):\(index + 1): \(code)")
        }
      }
    }
    #expect(scanned > 10, "the handler directory looks empty, which would make this vacuous")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a handler swallows a body it could not read; use `try request.values()`:\n"
          + offenders.joined(separator: "\n"))
    )
  }
}
