//  APIDocsView
//  The generated OpenAPI document, rendered by Scalar in a WKWebView.
//
//  WHY THE DOCUMENT IS GENERATED HERE and not read from `docs/api/openapi.json`: that file
//  is a CI artifact. `bb-openapi emit --check` diffs against it, which makes it a record of
//  what the table looked like at the last commit — and the one thing a committed document
//  can do is fall behind the table it describes. `OpenAPIDocument.generate()` runs off the
//  same `RouteCatalog` the router is built from, in this process, at open time. So this
//  window cannot describe a route this build does not serve, there is no build step to wire
//  up, and there is nothing for anyone to forget to regenerate.
//
//  WHY A WEBVIEW: the alternative is hand-writing a JSON Schema renderer — `$ref`
//  resolution, `allOf`/`oneOf` composition, nested object trees — to display a document
//  that, today, describes no body schemas at all. Scalar is 3.7MB of vendored JavaScript
//  and it is still the smaller thing to own. See DEPENDENCIES.md § Vendored assets.
//
//  The page it loads is hardened in `Resources/APIDocs/index.html`, which is where the
//  reasoning about Scalar's network defaults lives. The short version is that several of
//  them reach scalar.com and the page turns all of them off twice.

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
    case ready(specJSON: String)
    case failed(String)
  }

  var body: some View {
    Group {
      switch state {
      case .generating:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .ready(let specJSON):
        ScalarWebView(specJSON: specJSON)

      case .failed(let message):
        // `generate()` throws only on a duplicate operationId, which is a route-table bug
        // and not something a user can act on — so the message is shown verbatim rather
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
  /// will paste and watch fail on a server that moved port.
  private func generate() async {
    var serverURL = "http://localhost:1234"
    if let settings = model.settings {
      let port = await settings.get(Settings.socketPort)
      let configured = await settings.get(Settings.serverAddress)
      serverURL = configured.isEmpty ? "http://localhost:\(port)" : configured
    }

    do {
      let document = try OpenAPIDocument.generate(options: .init(serverURL: serverURL))
      state = .ready(specJSON: document.serialized())
    } catch {
      state = .failed(String(describing: error))
    }
  }
}

// MARK: - The web view

/// Scalar, loaded from the bundle with the document injected before any of it runs.
private struct ScalarWebView: NSViewRepresentable {

  /// The serialized OpenAPI document. Valid JSON is valid JavaScript, so this is injected
  /// as an object literal rather than parsed from a string at runtime.
  let specJSON: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()

    // `.atDocumentStart`, so `index.html`'s own script always finds it set. Injecting
    // afterwards would make the page race its own data and need a retry path for a
    // situation that cannot arise if the ordering is stated here.
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: "window.__BB_OPENAPI_SPEC__ = \(specJSON);",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
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
  /// The reference contains outbound links — Scalar's own attribution, and anything a
  /// route description happens to mention. Following one in-place would strand the user in
  /// a web browser wearing the app's window, with no back button (see above) to leave it.
  /// Anything that is not the local page is handed to the default browser instead, which
  /// also means the CSP in `index.html` never has to be the only thing standing between
  /// this view and the open internet.
  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
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
