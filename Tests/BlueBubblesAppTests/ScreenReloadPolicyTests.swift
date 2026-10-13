//  ScreenReloadPolicyTests
//  A page that reads from the server reads again when the server starts.
//
//  Every list page is a `ListPage` that switches between `ServerStoppedNotice` and its content,
//  and the notice carries a Start button. A bare `.task { await screen.reload() }` on that
//  group runs once, against no server, and never again, so pressing Start showed "No
//  devices" over a read that had not happened. `View.reloads(_:following:)` keys the read on
//  the phase; this scan refuses the bare form, in the shape of `ServerStoppedNoticeTests`.

import BBTestSupport
import Testing

@Suite("Screen reload policy")
struct ScreenReloadPolicyTests {

  /// Files whose bare `.task` is deliberate, by repository path, each with its reason.
  ///
  /// Empty on purpose. An exemption here is a page that reads from the server once and is
  /// content to show nothing until something else prompts it, which no page is.
  static let allowedFiles: Set<String> = []

  @Test("A screen's reload is keyed on the server phase, never a bare .task")
  func noBareReload() throws {
    // ANY bare `.task {` whose body awaits something, not just one that calls `reload()`.
    //
    // The old pattern matched the single literal `\.task { await x.reload() }`, which is why
    // the push setup page's defect survived a green suite: it spelled the same mistake as
    // `.task { await setup.refresh(push:) }`, and a `.task` with no `id` never re-runs when
    // the server phase changes, because the enclosing view's identity does not change.
    let pattern = try Regex(#"\.task\s*\{\s*await\s+\w+\.\w+\("#)

    // A FLOOR on what was scanned. A walk that finds nothing passes, and the rule this file
    // enforces then stops being enforced while looking exactly like compliance.
    let files = try SourceScanner.swiftFiles(under: "Sources/BlueBubblesApp", minimum: 11)
      // Only a file that also renders the stopped notice, which is what marks a view as one
      // that reads from the server. A `.task` on a view with no server state behind it has
      // nothing to re-run. A list page renders it through `ListPage`, so that counts too:
      // without it, every page moved onto the component would have dropped out of this scan.
      .filter { $0.code.contains("ServerStoppedNotice") || $0.code.contains("ListPage(") }
      .filter { !Self.allowedFiles.contains($0.path) }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a page reads once and goes stale when the server starts; "
          + "use `.reloads(screen, following: model)` or `.task(id: model.phase.isRunning)`:\n"
          + offences.report)
    )
  }
}
