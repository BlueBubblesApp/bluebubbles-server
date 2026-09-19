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

  /// Which drop zone the pointer is over, if any. Genuinely view-local: it is meaningless
  /// the moment the screen goes away.
  @State private var targeted: InspectedCredential.Kind?
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
    GlassCard {
      if status?.isConfigured == true {
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
      } else {
        VStack(alignment: .leading, spacing: 14) {
          // "Credentials" when one half is present: there is nothing to set UP any more,
          // there is a missing file to supply.
          Text(status?.hasServiceAccount == true ? "Credentials" : "Set up")
            .font(.headline)
          credentialForm
        }
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

    // Two zones, because there are two files. Either can be dropped on either
    // (classification reads the contents) but showing them apart is what makes a
    // missing half visible at a glance.
    HStack(spacing: 12) {
      dropZone(
        kind: .clientConfig,
        title: "google-services.json",
        caption: "Project Settings → Your apps",
        icon: "iphone.and.arrow.forward",
        isLoaded: status?.hasClientConfig == true
      )
      dropZone(
        kind: .serviceAccount,
        title: "Service account key",
        caption: "Service accounts → Generate new private key",
        icon: "key.fill",
        isLoaded: status?.hasServiceAccount == true
      )
    }

    HStack {
      Button("Choose Files…") {
        FirebaseCredentialImport.chooseFiles(into: setup, push: model.delivery.push)
      }
      .controlSize(.small)
      .disabled(setup.isBusy)
      Spacer()
    }

    Text(
      """
      Drop either file on either box; each is identified by reading it, not by \
      its name. They are stored in the Keychain and the originals are deleted.
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

  private func dropZone(
    kind: InspectedCredential.Kind,
    title: String,
    caption: String,
    icon: String,
    isLoaded: Bool
  ) -> some View {
    let isTargeted = targeted == kind
    return RoundedRectangle(cornerRadius: 12, style: .continuous)
      .strokeBorder(
        isTargeted ? Color.accentColor : Color.secondary.opacity(isLoaded ? 0.2 : 0.4),
        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isLoaded ? [] : [6, 4])
      )
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
      )
      .frame(height: 104)
      .overlay {
        VStack(spacing: 6) {
          Image(systemName: isLoaded ? "checkmark.circle.fill" : icon)
            .font(.title2)
            .foregroundStyle(isLoaded ? Color.green : (isTargeted ? Color.accentColor : .secondary))
          Text(title).font(.callout).multilineTextAlignment(.center)
          Text(isLoaded ? "Loaded" : caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(8)
      }
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .onDrop(
        of: [.fileURL],
        isTargeted: Binding(
          get: { targeted == kind },
          set: { targeted = $0 ? kind : nil }
        )
      ) { providers in
        FirebaseCredentialImport.accept(providers, into: setup, push: model.delivery.push)
      }
      .animation(.easeInOut(duration: 0.15), value: isTargeted)
      .accessibilityLabel("\(title) drop target")
  }
}
