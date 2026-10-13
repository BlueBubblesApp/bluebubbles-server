//  FirebaseCredentialImport
//  The browser hand-off for guided sign-in.
//
//  Dropped and chosen files do not come through here: `DropZone` and `acceptsFileDrop`
//  resolve them and hand them to `FirebaseSetupModel.importFiles` as one batch, which is the
//  rule that matters for this page (the two files usually arrive together, and importing
//  them one at a time restarts push between them and asks the project-change question about
//  a half-applied state).

import AppKit
import SwiftUI

enum FirebaseCredentialImport {

  /// Opens the consent page in the user's own browser rather than an embedded web view.
  /// Google refuses sign-in from embedded views, and this way the user signs in somewhere
  /// they can see the address bar.
  @Sendable
  static func openInBrowser(_ url: URL) async {
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
  }
}
