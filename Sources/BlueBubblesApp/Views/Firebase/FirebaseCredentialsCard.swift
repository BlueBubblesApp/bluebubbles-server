//  FirebaseCredentialsCard
//  The two files Firebase setup needs, and the guided path that fetches them for you.
//
//  **Two files, not one.** Firebase setup needs a service account key (this server sends with
//  it) AND a `google-services.json` (clients fetch it from this server to know which project
//  to register with). They are separate downloads from separate corners of Google's console,
//  and having one without the other is a real, silent half-state. The Electron page showed
//  them as two labelled drop zones for exactly that reason; collapsing them into a single
//  file chooser hid which one was missing, so this card puts them back.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseCredentialsCard: View {

  @Bindable var model: AppModel

  /// Whether the credential form is open on a server that is already set up.
  ///
  /// Collapsed by default, never hidden: swapping projects is rare, but this is the only
  /// route to it, and a page offering none would send someone to Disconnect, which drops
  /// every registered device with it.
  @State private var isReplacingCredentials = false

  private var setup: FirebaseSetupModel { model.firebaseSetup }
  private var status: PushStatus? { setup.status }

  /// The credential card, collapsed once there is nothing left to set up.
  ///
  /// Fully configured, this still drew a full-height card: two drop zones, a "Choose
  /// Files…" button, an explanation of how the files are classified, and four console
  /// links, directly under a summary already saying which project is connected. It read
  /// as an unfinished step on a finished setup, which on the onboarding walkthrough is
  /// exactly the wrong signal.
  ///
  /// A disclosure rather than a removal, for the reason on `isReplacingCredentials`.
  var body: some View {
    if status?.isConfigured == true {
      GlassCard {
        DisclosureGroup(isExpanded: $isReplacingCredentials) {
          VStack(alignment: .leading, spacing: 14) { credentialForm }
            .padding(.top, 14)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("Replace credentials").font(.headline)
            Text("Point this server at a different Firebase project.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    } else {
      // "Credentials" when one half is present: there is nothing to set UP any more,
      // there is a missing file to supply.
      TitledCard(status?.hasServiceAccount == true ? "Credentials" : "Set up") {
        credentialForm
      }
    }
  }

  /// The form itself, in one place so the collapsed and expanded cards cannot drift into
  /// two different forms.
  @ViewBuilder
  private var credentialForm: some View {
    if status?.isConfigured != true {
      Button {
        setup.beginGuidedSetup(
          push: model.delivery.push, openBrowser: FirebaseCredentialImport.openInBrowser)
      } label: {
        Label("Set up Firebase for me", systemImage: "wand.and.stars")
      }
      .disabled(setup.isBusy)

      Text(
        """
        Signs in to Google in your browser, then lets you pick an existing \
        Firebase project or create a new one. Either way this server is \
        configured for you, with locked-down security rules.
        """
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if let progress = setup.progress {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: Double(progress.index), total: Double(progress.total))
          Text(progress.step.rawValue).font(.caption)
        }
      }

      Divider()
    }

    Text("Or use a project you already have")
      .font(.subheadline).foregroundStyle(.secondary)

    // Two zones, because there are two files. Either can be dropped on (or chosen from)
    // either, because classification reads the contents, but showing them apart is what
    // makes a missing half visible at a glance.
    HStack(spacing: 12) {
      dropZone(
        title: "google-services.json",
        caption: "Project Settings → Your apps",
        symbol: "iphone.and.arrow.forward",
        isLoaded: status?.hasClientConfig == true
      )
      dropZone(
        title: "Service account key",
        caption: "Service accounts → Generate new private key",
        symbol: "key.fill",
        isLoaded: status?.hasServiceAccount == true
      )
    }

    Text(
      """
      Drop either file on either box, or choose them; each is identified by reading \
      it, not by its name. They are stored in the Keychain and the originals are deleted.
      """
    )
    .font(.caption).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)

    consoleLinks
  }

  /// Deep links into the Firebase console, as the Electron page had.
  ///
  /// Manual setup is the fallback when guided provisioning cannot work (an organisation
  /// policy on project creation, or Google's billing requirement for Firestore) so the
  /// path to the two downloads has to be reachable rather than described.
  private var consoleLinks: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Text("Firebase console").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        consoleLink("Enable Firestore", "firestore")
        consoleLink("Google Services Download", "settings/general")
        consoleLink("Admin SDK Download", "settings/serviceaccounts/adminsdk")
      }
      Link(
        "Manual setup instructions",
        destination: URL(
          string: "https://docs.bluebubbles.app/server/installation-guides/manual-setup"
        )!
      )
      .font(.caption)
    }
  }

  /// `project/_` is Google's own "whichever project I have open" placeholder, which is what
  /// the console redirects through when it does not know which one is meant.
  private func consoleLink(_ title: String, _ path: String) -> some View {
    Link(
      title,
      destination: URL(string: "https://console.firebase.google.com/u/0/project/_/\(path)")!
    )
    .font(.caption)
    .buttonStyle(.link)
  }

  // MARK: - Drop zones

  /// One of the two zones. Both hand every file to the same import, which classifies by
  /// reading: the zone a file lands on says which file is MISSING, not which file it is.
  private func dropZone(
    title: String, caption: String, symbol: String, isLoaded: Bool
  ) -> some View {
    DropZone(
      title: title,
      caption: caption,
      symbol: symbol,
      isLoaded: isLoaded,
      allowedContentTypes: [.json],
      chooserMessage: "Choose your service account key and google-services.json",
      isEnabled: !setup.isBusy
    ) { urls in
      setup.importFiles(urls, push: model.delivery.push)
    }
  }
}
