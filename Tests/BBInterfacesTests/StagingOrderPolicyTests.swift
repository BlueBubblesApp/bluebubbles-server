//  StagingOrderPolicyTests
//  An attachment is staged before `throughMessages`, never inside it.
//
//  `throughMessages` reports everything that fails inside it as Messages refusing: the 500
//  `iMessage Error` clients read for a failed send. Staging is a file copy on this server's
//  disk, and a copy that failed inside the closure reached a client as Messages having said
//  no. So a stage is its own statement, bound to a name before the closure, and that is the
//  shape scanned for: a call written inline as an argument is the one that ended up inside.

import BBTestSupport
import Foundation
import Testing

@Suite("Attachment staging order")
struct StagingOrderPolicyTests {

  @Test("Every stage is bound before the send that uses it")
  func stagingIsItsOwnStatement() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources/BBInterfaces", minimum: 10)
    var calls = 0
    let offences = SourceScanner.offences(in: files) { _, line in
      guard line.code.contains("AttachmentStaging.stage(") else { return false }
      calls += 1
      return !line.code.trimmingCharacters(in: .whitespaces).hasPrefix("let ")
    }
    #expect(calls >= 4, "found \(calls) staging calls; the scan is not reading the tree")
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "stage the attachment into a `let` before `throughMessages`:\n"
          + offences.report))
  }
}
