//  LandingHandlers
//  `GET /` — the page a browser gets.
//
//  A port of `UiRouter.index` (packages/server/.../routers/uiRouter.ts), which the Swift
//  server had never implemented. Two things made its absence worse than a missing endpoint
//  usually is:
//
//    - It is how people check a tunnel. The first thing someone does after configuring
//      cloudflared is paste the URL into a browser; a 404 there reads as "the tunnel is
//      broken" when the tunnel is fine.
//    - `landing_page_path` migrated across from an Electron install and was then read by
//      nothing, so an operator who had pointed it at their own page lost it silently. That
//      is the same "setting with no reader" class the settings audit was written to end.
//
//  Unauthenticated, matching Node's `unprotected` middleware — it exposes no server state.
//
//  The file is re-read on every request rather than cached, which looks like a missed
//  optimisation and is deliberate: this route is hit by hand, a few times, usually while
//  someone is editing the very file it serves. Caching would mean a restart to see a change,
//  to save a disk read nobody makes often enough to measure.
//
//  See `.claude/docs/api.md`.

import BBHTTPAPI
import BBInterfaces
import BBSettings
import Foundation

public enum LandingHandlers {

  public static func register(into registry: inout HandlerRegistry, context: some SettingsProviding)
  {
    registry.register(.uiIndex) { _ in
      page(configuredPath: await context.settings.get(Settings.landingPagePath))
    }
  }

  /// The whole decision, as a function of the setting.
  ///
  /// Split out from the handler so it is testable without standing up an `AppContext` — the
  /// three branches below are the behaviour worth pinning, and reaching them through a
  /// settings store would mean building the entire object graph to assert on a string.
  static func page(configuredPath: String) -> RouteResult {
    let path = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return html(defaultPage) }

    // Read, rather than check-then-read. `fs.existsSync` followed by `readFileSync` is
    // what Node does and it has a race in it; more usefully here, a path that exists but
    // cannot be READ — a file in a folder the server has no access to, which is a real
    // outcome on a Mac with tight permissions — would take the existence branch and then
    // throw, turning a configuration mistake into a 500. It also covers the case of a
    // path pointing at a directory, which `contents(atPath:)` reports as nil.
    guard let data = FileManager.default.contents(atPath: path) else {
      return html(missingPage)
    }

    // A page that is not UTF-8 is served as its own bytes with no charset asserted, so
    // its `<meta charset>` decides. Declaring `charset=utf-8` over a Latin-1 file would
    // override that meta tag and render mojibake — the header wins, so claiming an
    // encoding we have not verified is worse than claiming none.
    guard String(data: data, encoding: .utf8) != nil else {
      return .bytes(data, contentType: "text/html")
    }
    return .bytes(data, contentType: "text/html; charset=utf-8")
  }

  private static func html(_ body: String) -> RouteResult {
    // NOT `.data(...)`: this route returns a document, not the JSON envelope every other
    // route returns. A browser asked for a page.
    .bytes(Data(body.utf8), contentType: "text/html; charset=utf-8")
  }

  /// Byte-for-byte what `uiRouter.ts` serves, leading newline and template-literal
  /// indentation included — verified against a running Electron server at 250 bytes.
  ///
  /// The odd shape is not worth tidying. Node builds these from a template literal indented
  /// inside a class method, so the whitespace is an artifact of the source layout; matching
  /// it costs nothing and means the recorded fixture for `GET /` diffs clean instead of
  /// needing an exemption. Reformatting this is a parity failure, not a cleanup.
  static let defaultPage =
    "\n                <html>\n                    <title>BlueBubbles Server</title>\n"
    + "                    <body>\n                        "
    + "<h4>Welcome to the BlueBubbles Server landing page!</h4>\n"
    + "                    </body>\n                </html>\n            "

  /// Deliberately not a 404 or a 500. The server is fine and the route is fine; what is
  /// wrong is one setting, and the person who can fix it is the one reading this page.
  /// Same byte-for-byte transcription as above.
  static let missingPage =
    "\n                <html>\n                    <title>BlueBubbles Server</title>\n"
    + "                    <body>\n                        "
    + "<h4>[WARNING] Custom landing page not found!</h4>\n"
    + "                    </body>\n                </html>\n            "
}
