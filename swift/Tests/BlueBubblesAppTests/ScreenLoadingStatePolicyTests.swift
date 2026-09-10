//  ScreenLoadingStatePolicyTests
//  A page that reads from the server says so while it is reading.
//
//  Every list page decided what to draw by asking whether its collection was empty, and a
//  collection is empty before the first result lands. So each page announced its empty state
//  ("No devices", "Nothing scheduled", "No conversations were found") for the whole of the
//  read, then replaced it with rows.
//
//  The pages had already learned half of this: each guards its empty state against a read
//  that FAILED, because "Nothing scheduled" over a refused read is a lie with a button on it.
//  A read that has not finished is the same lie one moment earlier. `ScreenState` keeps
//  `idle` and `loading` apart precisely so a page can tell, and these pages were discarding
//  that by reading only `state.value`.
//
//  A comment saying "check the loading state" is read once; this runs on every build. In the
//  shape of `ScreenReloadPolicyTests`.

import Foundation
import Testing

@Suite("Screen loading state policy")
struct ScreenLoadingStatePolicyTests {

  /// Pages that compose a `ScreenModel` and deliberately never mention loading.
  ///
  /// One entry, and `ScreenModel`'s own header already names it: Home renders an em dash for
  /// a count it does not have yet. That is honest for a glance dashboard, where a spinner per
  /// tile would be more motion than the numbers are worth, and it never claims the count is
  /// zero, which is the failure this scan is about.
  private static let exempt: Set<String> = ["HomeView.swift"]

  @Test("A page whose content is a server read distinguishes empty from still loading")
  func everyScreenHandlesLoading() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BlueBubblesApp")

    var offenders: [String] = []
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      let name = URL(fileURLWithPath: relative).lastPathComponent
      guard !Self.exempt.contains(name) else { continue }
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      // Only the pages that actually compose one. A file that merely mentions the type
      // (this scan's own siblings, the modifier that reloads it) is not a screen.
      guard source.contains("ScreenModel {") || source.contains("ScreenModel<") else {
        continue
      }
      // Either spelling counts: a branch on `state.isLoading`, or a switch over the state
      // with a `.loading` case.
      let saysSomething =
        source.contains("state.isLoading") || source.contains("case .loading")
      if !saysSomething {
        offenders.append("Sources/BlueBubblesApp/\(relative)")
      }
    }

    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "these pages render an empty state while their first read is still in "
          + "flight; branch on `screen.state.isLoading` before the empty case, and show "
          + "`LoadingNotice`:\n" + offenders.joined(separator: "\n"))
    )
  }
}
