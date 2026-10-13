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

import BBTestSupport
import Foundation
import Testing

@Suite("Screen loading state policy")
struct ScreenLoadingStatePolicyTests {

  /// Files that compose a `ScreenModel` and deliberately never mention loading.
  ///
  /// `HomeView`, which `ScreenModel`'s own header already names: Home renders an em dash for
  /// a count it does not have yet. That is honest for a glance dashboard, where a spinner per
  /// tile would be more motion than the numbers are worth, and it never claims the count is
  /// zero, which is the failure this scan is about. And `HomeModel`, which is not a page: it
  /// HOLDS Home's two screens so they outlive the view, and draws nothing. The sections that
  /// draw them (`HomeActivitySection`, `HomeServerSection`) reach the screen through the
  /// model, so they never spell `ScreenModel<` and this scan does not see them; they say they
  /// are loading with a `Skeleton` of their own layout, which is Home's rule. And
  /// `PagedTableCard`, which is not a page either: it frames the list a page's `ListPage`
  /// has already decided (the loading notice, the empty state or the table), and takes the
  /// screen only to report its failure and to read again after a clamp.
  private static let exempt: Set<String> = [
    "HomeView.swift", "HomeModel.swift", "PagedTableCard.swift",
  ]

  @Test("A page whose content is a server read distinguishes empty from still loading")
  func everyScreenHandlesLoading() throws {
    var offenders: [String] = []
    // A FLOOR on what was scanned. A walk that finds nothing passes, and the rule this file
    // enforces then stops being enforced while looking exactly like compliance.
    for file in try Self.appSources(minimum: 11) {
      guard !Self.exempt.contains(file.name) else { continue }
      let source = file.code
      // Only the pages that actually compose one. A file that merely mentions the type
      // (this scan's own siblings, the modifier that reloads it) is not a screen.
      //
      // **This scopes on `ScreenModel`, so a page that reads the server WITHOUT one is
      // never checked.** That is a real hole and it is deliberate rather than overlooked:
      // widening it to every file showing `ServerStoppedNotice` would flag the pages that
      // read nothing and merely say the server is off, and the rule this enforces is about
      // a page whose CONTENT is a read. Closing it properly means being able to tell those
      // apart, which needs more than a grep. Recorded here rather than left implicit, and
      // the page that motivated it — the push setup page, which has its own state type — is
      // covered by `ScreenReloadPolicyTests` instead.
      guard source.contains("ScreenModel {") || source.contains("ScreenModel<") else {
        continue
      }
      // Any of three spellings counts: a branch on `state.isLoading`, a switch over the state
      // with a `.loading` case, or handing the screen to `ListPage`, which is the switch.
      let saysSomething =
        source.contains("state.isLoading") || source.contains("case .loading")
        || source.contains("ListPage(")
      if !saysSomething {
        offenders.append(file.path)
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

  /// A page's `body` draws something in EVERY state, and the compiler does not check it.
  ///
  /// `SubscriptionSettings` shipped as four `else if` branches with no final `else`. The state
  /// it left unnamed was the one every visit starts in — the server running, the read not yet
  /// made — so `body` produced no view at all. That is worse than a blank area: a view with
  /// nothing to draw has nothing to attach a modifier to, so the `.reloads` task that would
  /// have STARTED the read never ran. The page did not resolve a moment later; the tab was
  /// empty for as long as it was open, on a working server with a valid license.
  ///
  /// The check is coarse on purpose. It asks only whether the body's branching is closed —
  /// a `switch`, which the compiler makes exhaustive, or an `else` with no condition on it —
  /// because that is the property that was missing and it is one a grep can actually decide.
  /// It cannot tell whether a branch draws anything worth reading; `ScreenModel`'s own states
  /// are what the test above covers.
  @Test("A page that reads from the server draws something in every state")
  func everyScreenBodyIsTotal() throws {
    var offenders: [String] = []
    var scannedPages = 0
    for file in try Self.appSources() {
      guard !Self.exempt.contains(file.name) else { continue }
      let source = file.code
      guard source.contains("ScreenModel {") || source.contains("ScreenModel<") else {
        continue
      }
      guard let body = Self.body(of: source) else { continue }
      scannedPages += 1
      // Statement position only. Matching anywhere in the text reads the prose in a string
      // literal as code: this sheet's own subtitle says "sent even if this window is
      // closed", which contains `if ` and nothing else.
      let lines = body.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      let branches = lines.contains {
        $0.hasPrefix("if ") || $0.hasPrefix("} else if ") || $0.hasPrefix("switch ")
      }
      // No branching at all is total by definition: the body draws one thing.
      guard branches else { continue }
      let isClosed = lines.contains {
        $0.hasPrefix("switch ") || $0.hasPrefix("} else {") || $0.hasPrefix("else {")
      }
      if !isClosed { offenders.append(file.path) }
    }

    // The floor. A walk that finds no pages passes while enforcing nothing, and looks
    // exactly like compliance.
    #expect(
      scannedPages >= 5,
      Comment(
        rawValue: "found only \(scannedPages) pages composing a ScreenModel; this check is "
          + "not reading the tree"))

    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "these page bodies branch without a closing `else` or `switch`, so a state "
          + "they do not name renders nothing AND silently skips the `.task` that reads:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  /// A page whose whole content is a server read goes through `ListPage`.
  ///
  /// Five pages each wrote the stopped / switched off / loading / empty / rows decision as an
  /// `else if` chain, and the chains had drifted: one showed its empty state over a read that
  /// had failed, one drew nothing at all in a state it forgot. `ListPage` is the decision once,
  /// as a `switch`, and the scans above accept a page that hands its screen to it. That
  /// acceptance would be a hole if a page could compose a `ScreenModel` and still draw the
  /// whole-page stopped notice itself, so this refuses exactly that: the `.page` placement of
  /// `ServerStoppedNotice` in a file that composes a screen. A page that reads only one
  /// SECTION from the server (Subscription, with `.section`) is not a list page and is not
  /// caught.
  @Test("A page that reads a list from the server goes through ListPage")
  func listPagesGoThroughListPage() throws {
    let wholePageNotice = try Regex(#"placement:\s*\.page\(symbol:"#)

    var offenders: [String] = []
    var throughListPage = 0
    for file in try Self.appSources() {
      // The component itself is where the one whole-page notice for a list lives.
      guard file.name != "ListPage.swift", !Self.exempt.contains(file.name) else { continue }
      let code = file.code
      guard code.contains("ScreenModel {") || code.contains("ScreenModel<") else {
        continue
      }
      if code.contains("ListPage(") { throughListPage += 1 }
      if code.contains(wholePageNotice) {
        offenders.append(file.path)
      }
    }

    // The floor: the five list pages. Fewer means a page was moved off the component, or the
    // walk is not reading the tree; either way this check would be enforcing nothing.
    #expect(
      throughListPage >= 5,
      Comment(rawValue: "found only \(throughListPage) pages using ListPage; expected five"))
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "these pages compose a ScreenModel and draw the whole-page stopped notice "
          + "themselves; hand the screen to `ListPage`, which decides every state in one "
          + "`switch`:\n" + offenders.joined(separator: "\n"))
    )
  }

  /// The app's sources, every scan here reads.
  private static func appSources(minimum: Int = 1) throws -> [SourceFile] {
    try SourceScanner.swiftFiles(under: "Sources/BlueBubblesApp", minimum: minimum)
  }

  /// The text of `var body: some View { … }`, by brace matching.
  ///
  /// `stripped` is a file's code, comments already removed, so a brace inside prose cannot
  /// unbalance the count. A brace inside a string literal still could; none of these bodies
  /// has one, and the check this feeds fails loudly rather than silently if that changes.
  private static func body(of stripped: String) -> String? {
    guard let start = stripped.range(of: "var body: some View {") else { return nil }

    var depth = 0
    var index = stripped.index(before: start.upperBound)
    while index < stripped.endIndex {
      if stripped[index] == "{" { depth += 1 }
      if stripped[index] == "}" {
        depth -= 1
        if depth == 0 {
          return String(stripped[start.upperBound..<index])
        }
      }
      index = stripped.index(after: index)
    }
    return nil
  }
}
