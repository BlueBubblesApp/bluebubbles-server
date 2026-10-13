//  APIDocsStylesheetTests
//  The class names the API reference's own stylesheet reaches into still exist.
//
//  `Resources/APIDocs/index.html` styles a few things Scalar gives no configuration key for:
//  it hides the "Generate MCP" affordance, and it lifts the request-example picker out of the
//  card footer so the samples on `POST /message/query` are not announced below 300px of curl.
//  Both reach into the vendored bundle's own class names, and both fail SILENTLY when one is
//  renamed — the page still loads, nothing errors, the MCP link comes back and the picker
//  sinks. That is the failure the header of that file calls "the one piece of the page a
//  version bump can silently undo", and until now nothing held it.
//
//  So: every Scalar-namespaced class the page targets has to appear in the bundle beside it.
//  A grep, not a render, which is what makes it run on every build rather than in a WKWebView
//  with a run loop. It cannot prove the rule still has the effect it was written for; it
//  proves the hook is not dangling, which is the half that breaks on a bump.

import BBTestSupport
import Foundation
import Testing

@Suite("API docs stylesheet")
struct APIDocsStylesheetTests {

  /// `Sources/BlueBubblesApp/Resources/APIDocs`, from this file rather than the bundle: the
  /// resources are copied into the app, and a test that read the copy would pass on a stale
  /// one.
  private static var resources: URL {
    Repository.url("Sources/BlueBubblesApp/Resources/APIDocs")
  }

  private func read(_ name: String) throws -> String {
    try String(contentsOf: Self.resources.appendingPathComponent(name), encoding: .utf8)
  }

  /// The contents of the page's one `<style>` element.
  private func stylesheet(in page: String) throws -> String {
    let open = try #require(page.range(of: "<style>"), "the page has no <style> block")
    let close = try #require(
      page.range(of: "</style>", range: open.upperBound..<page.endIndex),
      "the page's <style> block is unterminated")
    return String(page[open.upperBound..<close.lowerBound])
  }

  /// Every `.scalar-…` / `.request-…` class the stylesheet selects on.
  ///
  /// Only those two prefixes: the rest of what the page styles is its own (`#fallback`) or
  /// standard (`html`, `body`, `:root`), and Scalar's utility classes (`truncate`, `bg-b-3`)
  /// are Tailwind's rather than names Scalar chose, so they are not the stable hooks this is
  /// about. The comment in `index.html` says why that distinction is the whole point.
  private func scalarClasses(in stylesheet: String) -> Set<String> {
    var found: Set<String> = []
    // Selectors only: a declaration block cannot contain a class token, and skipping them
    // keeps a value like `var(--scalar-font)` out of the results.
    for line in stylesheet.split(separator: "\n") where line.contains("{") {
      let selector = line.prefix { $0 != "{" }
      var rest = Substring(selector)
      while let dot = rest.firstIndex(of: ".") {
        let after = rest[rest.index(after: dot)...]
        let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if name.hasPrefix("scalar-") || name.hasPrefix("request-") { found.insert(String(name)) }
        rest = name.isEmpty ? after : after[name.endIndex...]
      }
    }
    return found
  }

  @Test("Every Scalar class the page styles is still in the vendored bundle")
  func hooksAreNotDangling() throws {
    let classes = scalarClasses(in: try stylesheet(in: try read("index.html")))
    // A floor, so the extraction silently returning nothing is itself a failure: it would
    // otherwise make this suite pass by finding nothing to check.
    #expect(
      classes.count >= 5,
      "found only \(classes.count) Scalar classes in the stylesheet; the extraction is wrong")

    let bundle = try read("scalar.standalone.js")
    for name in classes.sorted() {
      // The Bool is computed BEFORE the expectation on purpose. Handing `#expect` the
      // haystack makes it render the haystack on failure, and the haystack here is 3.7MB of
      // minified JavaScript: the one run that proved this test works printed 247KB of
      // Tailwind before reaching the point. A test nobody can read the failure of is a test
      // that gets deleted.
      let present = bundle.contains(name)
      #expect(
        present,
        """
        `\(name)` is styled by Resources/APIDocs/index.html and appears nowhere in \
        scalar.standalone.js. A version bump renamed it, so that rule now does nothing and \
        the page will have quietly gone back to Scalar's own layout.
        """)
    }
  }

  @Test("The picker rule names the class Scalar renders the picker into")
  func theExamplePickerHookIsSpelledRight() throws {
    // Named rather than left to the sweep above, because this one carries a second claim:
    // Scalar renders `request-card-footer-addon` ONLY for an operation with more than one
    // example, which is what scopes the reorder to the cards that need it. If the class
    // survives a bump but the condition does not, the `:has()` starts matching every card.
    let page = try read("index.html")
    let scoped = page.contains(":has(.request-card-footer-addon)")
    #expect(scoped, "the reorder no longer scopes itself to cards that have an example picker")

    // Anchored on a class list Scalar WROTE rather than on anything around it: the bundle is
    // minified, so every identifier beside this is a generated name that changes on a
    // rebuild, and a test keyed to one would fail on a version bump that changed nothing.
    let bundle = try read("scalar.standalone.js")
    let anchor = try #require(
      bundle.range(of: "class:`request-card-footer bg-b-3`"),
      "the bundle no longer renders a `request-card-footer`; the reorder has nothing to move")
    let windowStart =
      bundle.index(anchor.lowerBound, offsetBy: -160, limitedBy: bundle.startIndex)
      ?? bundle.startIndex
    let guardWindow = bundle[windowStart..<anchor.lowerBound]
    let gated = guardWindow.contains(".length>1")
    #expect(
      gated,
      """
      The footer no longer appears to be gated on there being more than one example. Check \
      what `:has(.request-card-footer-addon)` now matches before trusting the layout: the \
      reorder is scoped on the assumption that only a multi-sample card renders the addon.
      """)
  }
}
