//  FirebaseCredentialImport
//  Getting credential files from the person to the model: drops, the file panel, and the
//  browser hand-off for guided sign-in.
//
//  Shared by the page (the whole page is a drop target) and the credentials card (each zone
//  and the Choose Files button), so the batching rule below is decided once.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

enum FirebaseCredentialImport {

  /// Resolves dropped providers to URLs and hands them over as ONE batch.
  ///
  /// Batched deliberately: the two files are usually dropped together, and importing them
  /// one at a time restarts push between them and asks the project-change question about
  /// a half-applied state.
  @MainActor
  @discardableResult
  static func accept(
    _ providers: [NSItemProvider], into setup: FirebaseSetupModel, push: (any PushSetupProviding)?
  ) -> Bool {
    // Resolved on the main actor, where the providers live. `NSItemProvider` is not
    // Sendable and AppKit hands it to us here, so the resolution stays on this actor and
    // only the resulting URLs (which are Sendable) cross into the import.
    Task { @MainActor in
      var urls: [URL] = []
      for provider in providers {
        if let url = await resolve(provider) { urls.append(url) }
      }
      guard !urls.isEmpty else { return }
      setup.importFiles(urls, push: push)
    }
    return true
  }

  // On the main actor with its caller: `NSItemProvider` is not Sendable, so it must not
  // cross an isolation boundary on the way to being read.
  @MainActor
  private static func resolve(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url)
      }
    }
  }

  @MainActor
  static func chooseFiles(into setup: FirebaseSetupModel, push: (any PushSetupProviding)?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = true
    panel.message = "Choose your service account key and google-services.json"
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    setup.importFiles(panel.urls, push: push)
  }

  /// Opens the consent page in the user's own browser rather than an embedded web view.
  /// Google refuses sign-in from embedded views, and this way the user signs in somewhere
  /// they can see the address bar.
  @Sendable
  static func openInBrowser(_ url: URL) async {
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
  }
}
