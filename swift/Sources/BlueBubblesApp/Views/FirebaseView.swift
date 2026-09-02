//  FirebaseView
//  Push notification setup — the screen that makes `FirebaseProvisioner` reachable.
//
//  Push is OPTIONAL and this screen says so first, before it offers anything. A socket-only
//  or webhook-only install is a supported deployment that works perfectly, so the empty state
//  here is "not set up", not "misconfigured", and there is no warning colour anywhere on it.
//
//  Three ways in, matching `PushInterface`: create a project, import one, or arrive with
//  credentials migrated from an Electron install. See `docs/EVENTS.md`.
//
//  **Two files, not one.** Firebase setup needs a service account key (this server sends with
//  it) AND a `google-services.json` (clients fetch it from this server to know which project
//  to register with). They are separate downloads from separate corners of Google's console,
//  and having one without the other is a real, silent half-state. The Electron page showed
//  them as two labelled drop zones for exactly that reason; collapsing them into a single
//  file chooser hid which one was missing, so this screen puts them back.
//
//  All state lives on `FirebaseSetupModel`, not in `@State` here — see that file.

import AppKit
import BBHandlers
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseView: View {

  @Bindable var model: AppModel

  /// Which drop zone the pointer is over, if any. Genuinely view-local: it is meaningless
  /// the moment the screen goes away.
  @State private var targeted: InspectedCredential.Kind?
  @State private var confirmingDisconnect = false

  private var setup: FirebaseSetupModel { model.firebaseSetup }
  private var status: PushStatus? { setup.status }

  /// Which panel setup is currently waiting on a person for.
  ///
  /// Derived from the model rather than stored, so navigating away and back re-presents
  /// whatever the run is still parked on instead of stranding it.
  private enum SetupSheet: Identifiable {
    case projects
    case billing(projectId: String)

    var id: String {
      switch self {
      case .projects: "projects"
      case .billing(let projectId): "billing-\(projectId)"
      }
    }
  }

  private var activeSheet: SetupSheet? {
    if setup.isChoosingProject { return .projects }
    if let projectId = setup.pendingBillingProject { return .billing(projectId: projectId) }
    return nil
  }

  /// Dismissing by clicking away is the same as cancelling whichever panel is up.
  private func dismissActiveSheet() {
    if setup.pendingBillingProject != nil {
      setup.dismissBillingPrompt()
    } else {
      setup.cancelGuidedSetup()
    }
  }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ContentUnavailableView(
          "Server not running",
          systemImage: "bell.badge",
          description: Text("Start the server to set up push notifications.")
        )
      } else {
        ScrollView {
          VStack(spacing: 12) {
            summary
            // Directly under the summary, NOT at the foot of the page. As caption
            // text below the transcript this was routinely missed entirely — the
            // spinner stopped and, as far as the user could tell, nothing
            // happened.
            outcomeBanner
            if status?.hasServiceAccount == true { manage }
            setUp
            if setup.isProvisioning || !setup.transcript.isEmpty { transcript }
            notices
          }
          .padding(20)
        }
        // The WHOLE page is a drop target, matching the Electron page. Someone
        // dragging two files from Downloads should not have to hit a 100pt rectangle
        // with each of them.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
          accept(providers)
        }
      }
    }
    .task { await setup.refresh(push: model.pushSetup) }
    // ONE sheet modifier driving both panels. Two `.sheet(isPresented:)` on the same view
    // do not reliably coexist in SwiftUI — the second silently never presents — and these
    // two appear in sequence within a single setup run.
    .sheet(
      item: Binding(
        get: { activeSheet },
        set: { if $0 == nil { dismissActiveSheet() } }
      )
    ) { sheet in
      switch sheet {
      case .projects:
        ProjectPicker(
          projects: setup.projectChoices,
          onChoose: { setup.chooseProject($0, push: model.pushSetup) },
          onCancel: { setup.cancelGuidedSetup() }
        )
      case .billing(let projectId):
        BillingSheet(
          projectId: projectId,
          consoleURL: setup.billingConsoleURL,
          onContinue: { setup.resumeAfterBilling(push: model.pushSetup) },
          onCancel: { setup.dismissBillingPrompt() }
        )
      }
    }
    // Only shown when there is genuinely a decision — a project with no existing keys and
    // nothing held locally has exactly one possible action, and a dialog with one answer
    // is just an extra click.
    .confirmationDialog(
      "How should this server's Firebase key be handled?",
      isPresented: Binding(
        get: { setup.pendingKeyDecision != nil },
        set: { if !$0 { setup.cancelGuidedSetup() } }
      ),
      titleVisibility: .visible
    ) {
      if let plan = setup.pendingKeyDecision {
        if plan.canReuseHeldKey {
          Button("Keep Using the Current Key") {
            setup.chooseKeyStrategy(.reuseHeld, for: plan, push: model.pushSetup)
          }
        }
        Button("Create a New Key") {
          setup.chooseKeyStrategy(
            .mintNew(deletingExisting: false), for: plan, push: model.pushSetup
          )
        }
        if plan.existingUserManagedKeys > 0 {
          Button(
            "Create a New Key and Delete the Old \(plan.existingUserManagedKeys)",
            role: .destructive
          ) {
            setup.chooseKeyStrategy(
              .mintNew(deletingExisting: true), for: plan, push: model.pushSetup
            )
          }
        }
        Button("Cancel", role: .cancel) { setup.cancelGuidedSetup() }
      }
    } message: {
      if let plan = setup.pendingKeyDecision {
        Text(keyDecisionExplanation(plan))
      }
    }
    .confirmationDialog(
      "Disconnect Firebase from this server?",
      isPresented: $confirmingDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) { setup.disconnect(push: model.pushSetup) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        """
        Notifications will stop being delivered to closed apps until Firebase is set \
        up again. Your Firebase project itself is not changed, and everything else — \
        the socket, webhooks and the API — keeps working.
        """)
    }
    // Held on the model, so wandering off mid-question does not lose the pending import.
    .confirmationDialog(
      "This is a different Firebase project",
      isPresented: Binding(
        get: { setup.pendingProjectChange != nil },
        set: { if !$0 { setup.dismissProjectChange() } }
      ),
      titleVisibility: .visible
    ) {
      // The inspection is captured HERE, while the dialog is built. Reading it inside
      // the button action instead would find it already cleared: dismissing the dialog
      // runs the binding's setter on the same tap, and it wins the race — the import
      // would silently do nothing.
      if let pending = setup.pendingProjectChange {
        Button("Import and Clear Devices") {
          setup.resolveProjectChange(pending, clearDevices: true, push: model.pushSetup)
        }
        Button("Import and Keep Devices") {
          setup.resolveProjectChange(pending, clearDevices: false, push: model.pushSetup)
        }
      }
      Button("Cancel", role: .cancel) { setup.dismissProjectChange() }
    } message: {
      if let change = setup.pendingProjectChange?.projectChange {
        Text(
          """
          These credentials belong to \(change.to), but this server is set up with \
          \(change.from). Registered devices hold notification tokens issued by \
          \(change.from), which \(change.to) cannot deliver to — so they should be \
          cleared and your clients re-registered. Keep them only if you are \
          restoring the same project under a new key.
          """)
      }
    }
  }

  /// What each key option actually does.
  ///
  /// Deliberately precise about the blast radius, because the intuitive guess is wrong in
  /// both directions. Deleting a key does NOT disconnect anybody's phone: FCM registrations
  /// are scoped to the Firebase project, so they survive any number of key changes. What a
  /// deletion breaks is any OTHER server or script still holding one of those keys — a
  /// second BlueBubbles install on the same project, typically. Saying "this will
  /// invalidate connected devices" would frighten people away from the safe option and
  /// leave them relaxed about the one that actually breaks something.
  private func keyDecisionExplanation(_ plan: ProjectAdoptionPlan) -> String {
    var lines: [String] = []
    if let email = plan.serviceAccountEmail {
      lines.append("Project \(plan.projectId) uses \(email).")
    }
    if plan.canReuseHeldKey {
      lines.append(
        "This server already has a working key for this project, so it does not need "
          + "a new one."
      )
    }
    if plan.existingUserManagedKeys > 0 {
      lines.append(
        "There \(plan.existingUserManagedKeys == 1 ? "is 1 existing key" : "are \(plan.existingUserManagedKeys) existing keys") "
          + "on this account. Creating a new one leaves them working; deleting them "
          + "stops any OTHER server or script that uses them from sending "
          + "notifications."
      )
      // The obvious question this dialog raises, answered before it is asked. Google
      // hands over a key's private half exactly once, at creation, so an existing key
      // cannot be fetched back from the account — not by this server and not by
      // Google's own console. If the user still has the JSON, importing it is the way
      // to reuse it.
      if !plan.canReuseHeldKey {
        lines.append(
          "An existing key cannot be downloaded again — Google only ever releases "
            + "the private half once, when the key is created. If you still have "
            + "that JSON file, cancel and drop it onto this page instead."
        )
      }
    }
    lines.append(
      "Your registered devices are not affected either way — they are tied to the "
        + "Firebase project, not to a key."
    )
    return lines.joined(separator: " ")
  }

  /// What the last action did, stated where the user is looking.
  ///
  /// Carries a timestamp because several of these actions can legitimately report "nothing
  /// needed changing", and a repeat of an identical result would otherwise be
  /// indistinguishable from the button not working at all.
  @ViewBuilder
  private var outcomeBanner: some View {
    if let outcome = setup.outcome {
      GlassCard {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: outcome.symbol)
            .foregroundStyle(colour(for: outcome.kind))
          VStack(alignment: .leading, spacing: 2) {
            Text(outcome.text)
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
            Text(outcome.at.formatted(date: .omitted, time: .standard))
              .font(.caption).foregroundStyle(.tertiary)
          }
          Spacer(minLength: 0)
        }
      }
      // Keyed on identity, so a repeated action with the same text still animates and
      // therefore still reads as having happened.
      .id(outcome.id)
      .transition(.opacity)
    }
  }

  private func colour(for kind: FirebaseSetupModel.Outcome.Kind) -> Color {
    switch kind {
    case .success: .green
    case .info: .secondary
    case .failure: .red
    }
  }

  // MARK: - Summary

  private var summary: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: headlineIcon)
            .foregroundStyle(status?.isConfigured == true ? .green : .secondary)
          Text(headline).font(.headline)
          Spacer()
          if setup.isBusy { ProgressView().controlSize(.small) }
        }

        // The line that matters on an unconfigured server, and the reason this screen
        // has no warning colour: nothing here is broken.
        Text(subhead)
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let status, status.hasServiceAccount {
          HStack(spacing: 6) {
            if let projectId = status.projectId { Tag(projectId) }
            if let kind = status.databaseKind { Tag(kind) }
            Tag("\(status.registeredDevices) device\(status.registeredDevices == 1 ? "" : "s")")
          }
        }

        if let label = setup.activity.label {
          Text(label).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var headlineIcon: String {
    guard let status else { return "bell.slash" }
    if status.isConfigured { return "bell.badge.fill" }
    return status.hasServiceAccount ? "exclamationmark.triangle" : "bell.slash"
  }

  private var headline: String {
    guard let status, status.hasServiceAccount || status.hasClientConfig else {
      return "Push notifications are not set up"
    }
    return status.isConfigured
      ? "Push notifications are set up"
      : "Push notifications are half set up"
  }

  private var subhead: String {
    guard let status else { return "" }
    if status.isConfigured {
      return "Clients receive messages while the app is closed."
    }
    // Naming the missing half, and what it costs, rather than reporting a configured
    // server. This state must not render as complete success.
    if status.hasServiceAccount {
      return """
        This server has a service account key but no google-services.json, so it can \
        send notifications but clients cannot fetch the Firebase configuration they \
        need in order to register for any. Add the missing file below.
        """
    }
    if status.hasClientConfig {
      return """
        This server has a google-services.json but no service account key, so it \
        cannot send notifications or publish its address. Add the missing file below.
        """
    }
    return """
      Optional. Without it, clients get messages over the socket while they are \
      connected, and webhooks and ntfy still work — only background delivery to a \
      closed app needs Firebase.
      """
  }

  // MARK: - Set up

  private var setUp: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 14) {
        Text(status?.hasServiceAccount == true ? "Credentials" : "Set up")
          .font(.headline)

        if status?.isConfigured != true {
          Button {
            setup.beginGuidedSetup(push: model.pushSetup, openBrowser: open)
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

        // Two zones, because there are two files. Either can be dropped on either —
        // classification reads the contents — but showing them apart is what makes a
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
          Button("Choose Files…") { chooseFiles() }
            .controlSize(.small)
            .disabled(setup.isBusy)
          Spacer()
        }

        Text(
          """
          Drop either file on either box — each is identified by reading it, not by \
          its name. They are stored in the Keychain and the originals are deleted.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        consoleLinks
      }
    }
  }

  /// Deep links into the Firebase console, as the Electron page had.
  ///
  /// Manual setup is the fallback when guided provisioning cannot work — an organisation
  /// policy on project creation, or Google's billing requirement for Firestore — so the
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
        accept(providers)
      }
      .animation(.easeInOut(duration: 0.15), value: isTargeted)
      .accessibilityLabel("\(title) drop target")
  }

  // MARK: - Manage

  private var manage: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("Manage").font(.headline)

        let noDevices = (status?.registeredDevices ?? 0) == 0

        HStack {
          Button("Send Test Notification") { setup.sendTest(push: model.pushSetup) }
            .disabled(setup.isBusy || noDevices)
            // On the control itself, so hovering the greyed-out button answers
            // "why is this disabled?" where the question is actually asked. The
            // explanation in body text below reads as unrelated commentary rather
            // than as the reason.
            .help(
              noDevices
                ? "No device has registered for notifications yet, so there is "
                  + "nowhere to send a test."
                : "Send a test notification to every registered device.")
          Button("Check Security Rules") { setup.repairRules(push: model.pushSetup) }
            .disabled(setup.isBusy)
            .help(
              "Re-check your project's Firebase rules and lock them down if "
                + "they have become too permissive.")
          Spacer()
          Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
            .disabled(setup.isBusy)
        }

        if noDevices {
          // Names the BUTTON, so the sentence is visibly about the disabled control
          // rather than a general remark about devices.
          Label {
            Text(
              """
              “Send Test Notification” is unavailable because no device has \
              registered with this server yet. Open BlueBubbles on your phone \
              and connect it to this server, then come back.
              """
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "iphone.slash").foregroundStyle(.secondary)
          }
        }

        Divider()

        // The control for the Firebase command channel. The setting has always
        // existed and the service has always honoured it; until now nothing in the
        // application could change it, so the only way to close the channel was to
        // edit the database by hand.
        Toggle(
          isOn: Binding(
            get: { status?.remoteRestartEnabled ?? true },
            set: { setup.setRemoteRestart($0, push: model.pushSetup) }
          )
        ) {
          Text("Allow clients to restart this server")
        }
        .disabled(setup.isBusy)

        Text(
          """
          Clients can write a restart request into your Firebase project and this \
          server acts on it. Turning this off stops the server polling for those \
          requests at all. Leave it on if you use the restart button in the app.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Transcript

  /// The running account of a provisioning job.
  ///
  /// Present whether or not anyone was watching when it started — that is the point. The
  /// Electron page showed the same thing as a log table, and it is the only way a
  /// multi-minute operation reads as progress rather than as a hang.
  private var transcript: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Setup progress").font(.headline)
          Spacer()
          if setup.isProvisioning { ProgressView().controlSize(.small) }
        }
        VStack(alignment: .leading, spacing: 3) {
          ForEach(setup.transcript) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(entry.at.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
              Text(entry.text)
                .font(.caption)
                .foregroundStyle(entry.isFailure ? Color.red : .primary)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
          }
        }
      }
    }
  }

  // MARK: - Messages

  @ViewBuilder
  private var notices: some View {
    if !setup.rejectedFiles.isEmpty {
      GlassCard {
        VStack(alignment: .leading, spacing: 6) {
          Text("Some files were not used").font(.subheadline)
          // Per file. A drop of three where one is wrong should name that one,
          // rather than failing the whole drop with a single message.
          ForEach(setup.rejectedFiles) { file in
            Label("\(file.name) \(file.reason)", systemImage: "doc.questionmark")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    // Explained rather than warned about. The ID of an existing project cannot be
    // changed, so a warning here would name a problem with no available action; what
    // actually protects these installs is the rule remediation above.
    if status?.hasLegacyProjectIdentifier == true {
      Text(
        """
        This project was created by an older version, whose project IDs were short \
        enough to be guessed. The ID cannot be changed, so the server keeps its \
        security rules locked instead — “Check Security Rules” re-applies them.
        """
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Files

  /// Resolves dropped providers to URLs and hands them over as ONE batch.
  ///
  /// Batched deliberately: the two files are usually dropped together, and importing them
  /// one at a time restarts push between them and asks the project-change question about
  /// a half-applied state.
  private func accept(_ providers: [NSItemProvider]) -> Bool {
    // Resolved on the main actor, where the providers live. `NSItemProvider` is not
    // Sendable and AppKit hands it to us here, so the resolution stays on this actor and
    // only the resulting URLs — which are Sendable — cross into the import.
    Task { @MainActor in
      var urls: [URL] = []
      for provider in providers {
        if let url = await resolve(provider) { urls.append(url) }
      }
      guard !urls.isEmpty else { return }
      setup.importFiles(urls, push: model.pushSetup)
    }
    return true
  }

  private func resolve(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url)
      }
    }
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = true
    panel.message = "Choose your service account key and google-services.json"
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    setup.importFiles(panel.urls, push: model.pushSetup)
  }

  /// Opens the consent page in the user's own browser rather than an embedded web view.
  /// Google refuses sign-in from embedded views, and this way the user signs in somewhere
  /// they can see the address bar.
  @Sendable
  private func open(_ url: URL) async {
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
  }
}

/// Choosing which Firebase project this server should use.
///
/// Offered on every guided run, including when the account has no projects yet — the list is
/// then empty and "Create a new project" is the only row, which reads correctly rather than
/// as a dead end.
///
/// Adoption is the preferred outcome and the ordering says so. FCM registration tokens are
/// scoped to a project, so creating a new one silently invalidates every client already
/// registered against the old one; reusing a project is the difference between "reconnect
/// your phone" and nothing at all.
private struct ProjectPicker: View {

  let projects: [FirebaseProjectSummary]
  let onChoose: (String?) -> Void
  let onCancel: () -> Void

  @State private var selection: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Choose a Firebase project").font(.headline)
        Text(
          """
          Use a project you already have, or create a new one. Reusing the project \
          your clients are already registered with means they keep working without \
          reconnecting.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)

      Divider()

      List(selection: $selection) {
        Section {
          row(
            id: nil,
            title: "Create a new project",
            subtitle: "A fresh project, set up from scratch. Clients registered "
              + "with another project will need to reconnect.",
            icon: "plus.circle"
          )
        }
        if !projects.isEmpty {
          Section("Existing projects") {
            ForEach(projects) { project in
              row(
                id: project.projectId,
                title: project.displayName,
                subtitle: project.isActive
                  ? project.projectId
                  : "\(project.projectId) — being deleted, cannot be used",
                icon: "cube",
                enabled: project.isActive
              )
            }
          }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 220)

      Divider()

      HStack {
        Button("Cancel", role: .cancel) { onCancel() }
        Spacer()
        Button("Continue") { onChoose(selection) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 520, height: 460)
  }

  private func row(
    id: String?,
    title: String,
    subtitle: String,
    icon: String,
    enabled: Bool = true
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(enabled ? Color.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body)
        Text(subtitle)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .tag(id)
    .disabled(!enabled)
  }
}

/// Google requires a billing account on a project before it will create a Firestore database.
///
/// Presented as a step to complete, not as a failure, because that is what it is: by the time
/// this appears the project, its APIs, its Admin SDK key and its Android app all exist — only
/// the database is missing. Continuing resumes into that same project.
///
/// A sheet rather than a confirmation dialog specifically because it has to stay open while
/// the user goes to Google. Any button in a dialog dismisses it, so "Open Billing Settings"
/// would take the "Continue" button away with it.
private struct BillingSheet: View {

  let projectId: String
  let consoleURL: URL?
  let onContinue: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Label("Firebase needs a billing account", systemImage: "creditcard")
          .font(.headline)

        Text(
          """
          Google will not create the Firestore database this server uses until \
          project \(projectId) has a billing account attached. Everything else is \
          already set up.
          """
        )
        .fixedSize(horizontal: false, vertical: true)

        // The reassurance is the point. Being asked for a card by Google, to run
        // something advertised as free, reads as a trap — and the honest answer is
        // that the usage genuinely is free, so say so plainly rather than leaving
        // people to guess.
        Text(
          """
          Cloud Messaging is free, and this server writes a single small document \
          to the database. Adding billing should not result in a charge, and you \
          can downgrade the plan again afterwards.
          """
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
          Text("What to do").font(.subheadline).bold()
          step(1, "Open the billing settings for this project.")
          step(2, "Link a billing account, creating one if you do not have it.")
          step(3, "Come back here and continue — setup picks up where it stopped.")
        }
        .padding(.top, 2)

        if let consoleURL {
          Link(destination: consoleURL) {
            Label("Open Billing Settings", systemImage: "arrow.up.forward.square")
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(20)

      Divider()

      HStack {
        Button("Cancel Setup", role: .cancel) { onCancel() }
        Spacer()
        Button("Continue, I've Configured Billing") { onContinue() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 540)
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      Text(text).font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}
