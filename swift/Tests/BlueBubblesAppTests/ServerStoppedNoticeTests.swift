//  ServerStoppedNoticeTests
//  A page does not write its own "server not running" state.
//
//  `ServerStoppedNotice` is the one place that sentence lives, and the one place with the
//  Start button on it. A page that writes the sentence itself is a page with no remedy, which
//  is what nine of them were. A source scan, in the shape of `AccessibilityPolicyTests`,
//  because a SwiftUI view cannot be inspected from a test without trapping.

import Foundation
import Testing

@Suite("Server-stopped placeholders")
struct ServerStoppedNoticeTests {

  @Test("Only ServerStoppedNotice spells the server-not-running placeholder")
  func onePlaceholder() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BlueBubblesApp")
    let pattern = try Regex(#""Server not running"|"Start the server to "#)

    var offenders: [String] = []
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      if relative.hasSuffix("ServerStoppedNotice.swift") { continue }
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        if code.contains(pattern) {
          offenders.append("Sources/BlueBubblesApp/\(relative):\(index + 1): \(code)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a page writes its own stopped-server placeholder; use `ServerStoppedNotice`:\n"
          + offenders.joined(separator: "\n"))
    )
  }
}
