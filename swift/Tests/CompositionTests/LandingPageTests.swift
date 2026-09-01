//  LandingPageTests
//  `GET /` serves a page, and the operator can replace it.
//
//  Two halves, because the failure modes are in different places. The mounting half runs a
//  real Hummingbird listener — the same reason `PathParameterTests` does: the bug this route
//  is fixing was that `/` answered 404, which is a routing fact no handler-level test can
//  see. The selection half is a pure function, so the three branches get asserted without
//  building an `AppContext` to hold one string.
//
//  Reference: packages/server/src/server/api/http/api/v1/routers/uiRouter.ts

import BBAuth
import BBHTTPAPI
import BBSerialization
import BBSettings
import Foundation
import Hummingbird
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Landing page")
struct LandingPageTests {

  // MARK: - Which page

  @Test("With no path configured, the built-in page is served")
  func defaultPageWhenUnset() throws {
    let body = try Self.text(of: LandingHandlers.page(configuredPath: ""))

    #expect(body.contains("Welcome to the BlueBubbles Server landing page!"))
  }

  /// Byte-for-byte against a real Electron server, captured from `curl http://…:1234/`.
  ///
  /// The leading newline and the template-literal indentation are an artifact of how
  /// `uiRouter.ts` is laid out, and reproducing them is free. Pinning the LENGTH as well as
  /// the content is what makes reformatting the constant fail here rather than in a
  /// recorded fixture much later.
  @Test("The default page matches the Electron server byte for byte")
  func defaultPageIsByteIdenticalToNode() throws {
    let recorded =
      "\n                <html>\n"
      + "                    <title>BlueBubbles Server</title>\n"
      + "                    <body>\n"
      + "                        <h4>Welcome to the BlueBubbles Server landing page!</h4>\n"
      + "                    </body>\n                </html>\n            "

    let body = try Self.text(of: LandingHandlers.page(configuredPath: ""))

    #expect(body == recorded)
    #expect(Data(body.utf8).count == 250)
  }

  /// Whitespace, because a path typed into a text field arrives with it and an operator who
  /// cleared the field by selecting and deleting can leave a space behind. Treating " " as
  /// a configured path would serve the warning page to someone who thinks they reset it.
  @Test("A whitespace-only path counts as unset")
  func whitespaceIsUnset() throws {
    let body = try Self.text(of: LandingHandlers.page(configuredPath: "   \n "))

    #expect(body.contains("Welcome to the BlueBubbles Server landing page!"))
  }

  /// The whole point of the setting.
  @Test("A configured file replaces the built-in page")
  func customPageIsServed() throws {
    let custom = "<html><body><h1>My Server</h1></body></html>"
    let url = try Self.writeTemporaryFile(custom)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = LandingHandlers.page(configuredPath: url.path)

    #expect(try Self.text(of: result) == custom)
    #expect(Self.contentType(of: result) == "text/html; charset=utf-8")
  }

  /// Node's behaviour, and worth keeping: the server is fine and the route is fine, so this
  /// is not a 404 or a 500. One setting is wrong, and the person who can fix it is the one
  /// looking at the page.
  @Test("A path that does not resolve serves the warning page, not an error")
  func missingFileWarns() throws {
    let body = try Self.text(
      of: LandingHandlers.page(configuredPath: "/tmp/bb-no-such-landing-page-9f2a.html")
    )

    #expect(body.contains("[WARNING] Custom landing page not found!"))
  }

  /// `contents(atPath:)` reports a directory as nil, which lands on the same branch — worth
  /// pinning, because pointing the setting at a folder is an easy mistake and a crash or a
  /// 500 would be a bad answer to it.
  @Test("A directory is treated as unresolvable rather than read")
  func directoryWarns() throws {
    let body = try Self.text(
      of: LandingHandlers.page(configuredPath: NSTemporaryDirectory())
    )

    #expect(body.contains("[WARNING] Custom landing page not found!"))
  }

  /// A page that is not UTF-8 keeps its bytes and asserts no charset, so its own
  /// `<meta charset>` decides. A `charset=utf-8` header would OVERRIDE that meta tag and
  /// render mojibake — the header wins, so claiming an encoding we have not verified is
  /// worse than claiming none.
  @Test("A non-UTF-8 page is served as its own bytes with no charset claimed")
  func nonUTF8KeepsItsBytes() throws {
    // Latin-1 "Café" — 0xE9 is a valid Latin-1 é and an invalid UTF-8 sequence.
    var bytes = Data("<html><body>Caf".utf8)
    bytes.append(0xE9)
    bytes.append(contentsOf: Data("</body></html>".utf8))

    let url = try Self.writeTemporaryFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = LandingHandlers.page(configuredPath: url.path)

    #expect(Self.contentType(of: result) == "text/html")
    #expect(Self.data(of: result) == bytes)
  }

  // MARK: - That it is mounted at all

  /// The bug being fixed. `/` answered 404 on every install, which no handler-level test
  /// can see — the handler was never reached because the route did not exist.
  ///
  /// The server here has a REAL password scheme installed, and `ping` is asserted to 401
  /// under it. That negative control is the whole value of the test: with an empty scheme
  /// chain everything is open, so "the landing page answered 200" would prove nothing about
  /// whether it is authenticated. Node serves `/` through its `unprotected` middleware, and
  /// a browser has no password to offer.
  @Test("GET / answers with HTML and needs no password, while the API still does")
  func rootIsMountedAndUnauthenticated() async throws {
    var registry = HandlerRegistry()
    registry.register("ui.index") { _ in LandingHandlers.page(configuredPath: "") }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    // Port 0: the kernel picks a free port and never picks one it has already given
    // out. See `EphemeralPort`.
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(host: "127.0.0.1", port: 0),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: [
          PasswordQueryScheme(
            passwordProvider: { PasswordDigest("hunter2hunter2") }
          )
        ]),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    let router = try builder.buildRouter(registry: registry)

    let listener = HTTPListener()
    try await listener.start(router: router, host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }
    let port = try await listener.boundPortOrFail()

    // The control: an ordinary API route with no credential is refused, so the scheme is
    // demonstrably installed and demonstrably working.
    let (_, pingResponse) = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(port)/api/v1/ping")!
    )
    #expect((pingResponse as? HTTPURLResponse)?.statusCode == 401)

    // And the landing page, with the same absent credential.
    let (data, response) = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(port)/")!
    )
    let http = try #require(response as? HTTPURLResponse)

    #expect(http.statusCode == 200)
    #expect((http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("text/html"))

    // HTML, not the JSON envelope every other route returns. A browser asked for a page.
    let body = String(decoding: data, as: UTF8.self)
    #expect(body.contains("Welcome to the BlueBubbles Server landing page!"))
    #expect(!body.contains("\"status\""))
  }

  // MARK: - Helpers

  private static func data(of result: RouteResult) -> Data? {
    guard case .bytes(let data, _) = result else { return nil }
    return data
  }

  private static func contentType(of result: RouteResult) -> String? {
    guard case .bytes(_, let contentType) = result else { return nil }
    return contentType
  }

  private static func text(of result: RouteResult) throws -> String {
    let data = try #require(Self.data(of: result), "expected a .bytes result")
    return String(decoding: data, as: UTF8.self)
  }

  private static func writeTemporaryFile(_ contents: String) throws -> URL {
    try writeTemporaryFile(Data(contents.utf8))
  }

  private static func writeTemporaryFile(_ contents: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-landing-\(UUID().uuidString).html")
    try contents.write(to: url)
    return url
  }
}
