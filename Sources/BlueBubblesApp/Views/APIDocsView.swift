//  APIDocsView
//  The generated OpenAPI document, rendered by Scalar in a WKWebView.
//
//  WHY THE DOCUMENT IS GENERATED HERE and not read from `docs/api/openapi.json`: that file
//  is a CI artifact. `bb-openapi emit --check` diffs against it, in
//  `.github/workflows/swift-gate.yml`, which makes it a record of what the table looked like
//  at the last commit, and the one thing a committed document can do is fall behind the
//  table it describes. `OpenAPIDocument.generate()` runs off `RouteCatalog.routes` —
//  `RouteTable.groups`, plus the additive groups `ServerComposition.routeGroups` mounts —
//  in this process, at open time. So this window cannot describe a route this binary does
//  not carry, there is no build step to wire up, and there is nothing for anyone to forget
//  to regenerate. The catalog names the additive groups a second time rather than reading
//  them off the composition root, which is the one seam, and it is the direction that would
//  break this claim: `RouteRegistrationTests.catalogueIsReachable` fails on a catalog entry
//  no configuration mounts.
//
//  WHY A WEBVIEW: the alternative is hand-writing a JSON Schema renderer, and the document
//  it would have to render is precisely the shape that makes one expensive. Every described
//  success response is an `allOf` composing a `$ref` to `ResponseEnvelope` with an inline
//  `data` schema (`OpenAPIDocument.responses(for:operationID:unauthenticated:needsHelper:)`);
//  `POST /api/v2/sticker` splits its `data` further into a `oneOf` over two variants
//  (`ResponseBodies.byHandler`); the schemas nest objects inside arrays inside objects, and
//  `POST /api/v1/message/query` carries a named `examples` map a reader is expected to
//  render as a picker (`RequestBodies`). They reach the document either from the recorded
//  corpus, by way of `Resources/schemas.json` and `FixtureSchemas` — a resource for this
//  exact reason, since the app has no `Fixtures/http/` to read — or declared by hand in
//  `RequestBodies`, `ResponseBodies` and `MultipartBodies`. So `$ref` resolution, `allOf`
//  and `oneOf` composition, recursion into nested objects and an example picker are all
//  load-bearing before a single operation renders. `Resources/APIDocs/scalar.standalone.js`
//  is 3.7 MB of vendored JavaScript and it is still the smaller thing to own. See
//  DEPENDENCIES.md § Vendored assets, which records its version and digest.
//
//  The page it loads is hardened in `Resources/APIDocs/index.html`, which is where the
//  reasoning about Scalar's network defaults lives. The short version is that several of
//  them reach scalar.com and the page turns all of them off twice.
//
//  WHY "TRY IT" WORKS FROM A PAGE THAT CANNOT REACH THE NETWORK: it does not. The page's
//  own CSP keeps `connect-src 'none'` (`index.html`), and Scalar's `customFetch` hands every
//  request to `APIDocsRelay` over `WKScriptMessageHandlerWithReply`, which is a message port
//  and not a fetch, so CSP does not reach it. `URLSession`, inside this process, makes the
//  call. That file is where the reasoning lives.

import BBCore
import BBInterfaces
import BBOpenAPI
import BBSettings
import BlueBubblesServerCore
import SwiftUI
import WebKit

struct APIDocsView: View {

  /// The scene id. Shared by the menu item and the button on the API & Webhooks page so
  /// the two open the same window instead of racing to create two of them.
  static let windowID = "api-docs"

  let model: AppModel

  /// Explicit because `@State private var state` below makes the memberwise initializer
  /// private, and the scene in `BlueBubblesApp` has to be able to call it.
  init(model: AppModel) {
    self.model = model
  }

  @State private var state: LoadState = .generating

  enum LoadState {
    case generating
    case ready(Document)
    case failed(String)
  }

  /// What the web view needs to render and to send: the document, where its client is
  /// allowed to send, and the credential to fill the Auth panel in with.
  struct Document {
    let specJSON: String
    let allowedOrigins: Set<String>
    let password: String
  }

  var body: some View {
    Group {
      switch state {
      case .generating:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .ready(let document):
        ScalarWebView(document: document)

      case .failed(let message):
        // `generate()` throws only on a duplicate operationId, which is a route-table bug
        // and not something a user can act on, so the message is shown verbatim rather
        // than translated into advice that would be wrong.
        ContentUnavailableView(
          "The API document could not be generated",
          systemImage: "exclamationmark.triangle",
          description: Text(message)
        )
      }
    }
    .task { await generate() }
  }

  /// Builds the document, pointing its `servers` entry at the address this install
  /// actually answers on.
  ///
  /// That is not cosmetic: Scalar renders a copyable `curl` for every operation, and a
  /// sample built against the generator's `http://localhost:1234` default is one somebody
  /// will paste and watch fail on a server that moved port. The address is the model's
  /// followed `clientAddress`, in its from-this-Mac form, since the samples run here.
  private func generate() async {
    // With no server the document is still worth generating: it describes this version's
    // routes, and the setting's default says where a default install would answer. So no
    // server is not a failure here: the password read is skipped rather than left to throw.
    let port = model.clientAddress.port ?? Settings.socketPort.defaultValue
    let serverURL = model.clientAddress.forThisMac ?? "http://localhost:\(port)"
    var password = ""
    do {
      if model.settings.isAvailable {
        // Read for one purpose: prefilling the console's Auth panel, so pressing Send works
        // without the operator going to find a password the window beside this one holds.
        // It is injected into the web view and never logged, never written to disk
        // (Scalar's `persistAuth` stays off), and never leaves the process except on a
        // request the operator asked for, to an origin in the set below.
        password = try await model.settings.get(Settings.password)
      }

      let document = try OpenAPIDocument.generate(options: .init(serverURL: serverURL))
      state = .ready(
        Document(
          specJSON: document.serialized(),
          allowedOrigins: APIDocsRelayPolicy.allowedOrigins(
            serverURL: serverURL, loopbackPort: port),
          password: password
        )
      )
    } catch {
      state = .failed(DiagnosticText.sentence(for: error))
    }
  }
}

// MARK: - The web view

/// Scalar, loaded from the bundle with the document injected before any of it runs.
private struct ScalarWebView: NSViewRepresentable {

  let document: APIDocsView.Document

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let controller = configuration.userContentController

    // `.atDocumentStart`, so `index.html`'s own script always finds these set. Injecting
    // afterwards would make the page race its own data and need a retry path for a
    // situation that cannot arise if the ordering is stated here.
    //
    // The document is interpolated raw because valid JSON is valid JavaScript; the password
    // goes through `JSONSerialization`, because it is a value a person typed and one
    // apostrophe in it would otherwise end the statement early — at best a syntax error, at
    // worst an injection into this page's own script.
    let prefill = APIDocsPagePrefill.authentication(password: document.password)
    controller.addUserScript(
      WKUserScript(
        source: "window.__BB_OPENAPI_SPEC__ = \(document.specJSON);\n"
          + "window.__BB_PREFILL_AUTH__ = \(prefill);",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )

    // The port Scalar's `customFetch` posts to. Added in `.page` rather than an isolated
    // world because the caller is the page's own script.
    controller.addScriptMessageHandler(
      context.coordinator.relay(allowedOrigins: document.allowedOrigins),
      contentWorld: .page,
      name: APIDocsRelay.messageHandlerName
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    // There is one page and no history. Rubber-banding a document that cannot navigate
    // reads as a broken scroll view.
    webView.allowsBackForwardNavigationGestures = false

    guard
      let index = Bundle.module.url(
        forResource: "index", withExtension: "html", subdirectory: "APIDocs")
    else {
      // The resource is copied by SwiftPM, so a miss here means the bundle was built
      // wrong rather than anything about this run. Fail loudly in debug.
      assertionFailure("APIDocs/index.html is missing from the app bundle")
      return webView
    }

    // Read access is scoped to the APIDocs directory, not the whole bundle: the page needs
    // exactly one sibling file and nothing else in the app is its business.
    webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {}

  /// Keeps the web view on the bundled page.
  ///
  /// The reference contains outbound links: Scalar's own attribution, and anything a
  /// route description happens to mention. Following one in-place would strand the user in
  /// a web browser wearing the app's window, with no back button (see above) to leave it.
  /// Anything that is not the local page is handed to the default browser instead, which
  /// also means the CSP in `index.html` never has to be the only thing standing between
  /// this view and the open internet.
  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {

    /// Held here so it lives exactly as long as the view does. `WKUserContentController`
    /// retains a message handler as well, and nothing releases that on its own.
    private var messageRelay: APIDocsRelay?

    func relay(allowedOrigins: Set<String>) -> APIDocsRelay {
      let relay = APIDocsRelay(allowedOrigins: allowedOrigins)
      messageRelay = relay
      return relay
    }
    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let url = navigationAction.request.url else { return .cancel }
      if url.isFileURL { return .allow }
      NSWorkspace.shared.open(url)
      return .cancel
    }
  }
}
