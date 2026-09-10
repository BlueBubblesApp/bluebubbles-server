//  ScreenReloadPolicyTests
//  A page that reads from the server reads again when the server starts.
//
//  Every list page is a `Group` that switches between `ServerStoppedNotice` and its content,
//  and the notice carries a Start button. A bare `.task { await screen.reload() }` on that
//  group runs once, against no server, and never again, so pressing Start showed "No
//  devices" over a read that had not happened. `View.reloads(_:following:)` keys the read on
//  the phase; this scan refuses the bare form, in the shape of `ServerStoppedNoticeTests`.

import Foundation
import Testing

@Suite("Screen reload policy")
struct ScreenReloadPolicyTests {

  @Test("A screen's reload is keyed on the server phase, never a bare .task")
  func noBareReload() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BlueBubblesApp")
    let pattern = try Regex(#"\.task\s*\{\s*await\s+\w+\.reload\(\)"#)

    var offenders: [String] = []
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
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
        rawValue: "a page reads once and goes stale when the server starts; "
          + "use `.reloads(screen, following: model)` or `.task(id: model.phase.isRunning)`:\n"
          + offenders.joined(separator: "\n"))
    )
  }
}
