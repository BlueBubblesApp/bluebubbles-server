//  OnboardingView
//  The setup walkthrough: a rail of steps, the current step, and the way forward.
//
//  What is asked and in what order comes from `OnboardingCatalog` via `OnboardingModel`;
//  this file is the shell. It owns exactly the state a gate has to be certain of (the typed
//  password, and whether the permission skip was acknowledged) and builds the
//  `OnboardingProgress` a step's gate decides on.
//
//  See `Onboarding/OnboardingFlow.swift` for the rules and `.claude/docs/architecture.md`.

import BBBuiltIns
import BBCore
import BBServiceKit
import BBSettings
import BBSystem
import BlueBubblesServerCore
import Logging
import SwiftUI

struct OnboardingView: View {

  @Bindable var model: AppModel

  @State private var acknowledgedSkip = false
  /// "Set this up later", over a connection method whose program is not on this Mac. See
  /// `OnboardingRules.connectionGate`.
  @State private var acknowledgedToolSkip = false
  // Owned HERE rather than inside the password step, because the Continue button has to be
  // able to both refuse to advance on a bad password and persist a good one. While the step
  // owned them, it could only offer a Save button of its own, and skipping that button was
  // exactly how a server ended up with no password at all.
  @State private var password = ""
  /// Seeded from `Settings.socketPort` by `readConfiguredPort`, never left at a literal.
  ///
  /// This field is WRITTEN BACK by `saveCredentials` whenever the goals ask for a port, so
  /// a hard-coded starting value is not a cosmetic default: a server migrated on 8080 was
  /// shown 1234 and then silently moved to it by somebody clicking Continue past a step
  /// they had no reason to touch.
  @State private var port = Settings.socketPort.defaultValue
  /// Why Continue could not save the password or the port. Shown on the card holding them,
  /// because it is about what is typed there.
  @State private var saveError: String?
  /// Why a read the walkthrough makes could not be made, by which read. Its own slot per
  /// read, because one slot for all of them was cleared by whichever read next succeeded
  /// and showed a failure to read the Private API switch under the password field.
  @State private var readProblems: [OnboardingRead: String] = [:]
  @State private var missingConnectionFields: [FieldDescriptor] = []

  /// Whether the store ALREADY holds a password: a second run of setup, or an adopted
  /// Electron install whose password came across in the migration.
  ///
  /// Asked because the field cannot answer it. The stored password is deliberately never
  /// read back into the text field, so an empty field means "not set" on a fresh install and
  /// "set, and not shown" on every other, and treating the second as the first is what made
  /// a migrated server demand a new password on a step that then OVERWROTE the working one.
  /// Whether it exists is not a secret; its value is, and that is never materialised here:
  /// `SettingsModel.secret` answers with a `SecureString`, and only `isEmpty` is read.
  @State private var hasStoredPassword = false

  private var onboarding: OnboardingModel { model.onboarding }
  private var step: OnboardingStep { onboarding.current }

  var body: some View {
    HStack(spacing: 0) {
      rail
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        content
        Divider()
        footer
      }
    }
    // Minimum and ideal rather than a fixed size, so the sheet can be resized when the text
    // is larger than the default and so it fits inside a window at its minimum height,
    // which is set to hold it (see `BlueBubblesApp`).
    .sheetFrame(.onboarding)
    .task { await model.permissions.refresh() }
    .task { await readStoredPassword() }
    // Once on appearance, deliberately NOT keyed on the phase: this seeds an editable
    // field, and re-running it when the server restarts would overwrite a port the person
    // was in the middle of typing.
    .task { await readConfiguredPort() }
    // Keyed on the phase, because it reads from the server and the walkthrough can be
    // reopened from the menu over a server that is still starting. Re-running is harmless:
    // `hasSeededGoalsFromServer` makes it a no-op after the first time it succeeds.
    .task(id: model.phase.isRunning) { await seedGoalsFromServer() }
    // Read when the method changes and whenever one of its settings is written; see
    // `connectionVersion`.
    .task(
      id: ConnectionKey(method: onboarding.selections.connectionMethod, version: connectionVersion)
    ) {
      await refreshConnectionState()
    }
    // Read on appearance and whenever the switch is written, so the plan drops or adds the
    // group-chat Shortcut step the moment the toggle on the Private API step moves.
    .task(id: model.settings.version(of: [Settings.enablePrivateAPI.key])) {
      await mirrorPrivateAPIState()
    }
    .task(id: model.integrations.selectedConnectionMethod) {
      // The connection step writes through `IntegrationsModel`; mirror what it holds so the
      // plan and the gate see the same answer.
      let selected = model.integrations.selectedConnectionMethod
      onboarding.selections.connectionMethod = selected.isEmpty ? nil : selected
    }
  }

  // MARK: - The rail

  private var rail: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Setup")
        .font(.title3.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
      ForEach(Array(onboarding.plan.enumerated()), id: \.element.id) { index, entry in
        railRow(entry, index: index)
      }
      Spacer()
    }
    .padding(16)
    .frame(width: 210)
  }

  private func railRow(_ entry: OnboardingStep, index: Int) -> some View {
    let isCurrent = entry.id == step.id
    let isDone = index < onboarding.position
    return Button {
      onboarding.jump(to: entry.id)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isDone ? "checkmark.circle.fill" : entry.symbol)
          .foregroundStyle(
            isDone ? StatusTone.good.tint : isCurrent ? Color.accentColor : .secondary
          )
          .frame(width: SettingsMetrics.iconColumnWidth)
        Text(entry.title)
          .font(isCurrent ? .body.weight(.semibold) : .body)
          .foregroundStyle(isCurrent || isDone ? .primary : .secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      // The system's own selection fill, as a sidebar row has, rather than a tint of the
      // accent colour picked here: it follows the accent and the appearance on its own.
      .background(
        RoundedRectangle(cornerRadius: SettingsMetrics.rowCornerRadius, style: .continuous)
          .fill(isCurrent ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Only steps already walked are reachable from the rail; the ones ahead depend on
    // answers not given yet.
    .disabled(index > onboarding.position)
  }

  // MARK: - The step

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(step.title).font(.title.weight(.semibold))
      let purpose = step.purpose(onboarding.selections)
      if !purpose.isEmpty {
        Text(purpose)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
  }

  @ViewBuilder
  private var content: some View {
    let stepView = OnboardingStepView(
      step: step.id,
      model: model,
      password: $password,
      port: $port,
      acknowledgedSkip: $acknowledgedSkip,
      acknowledgedToolSkip: $acknowledgedToolSkip,
      passwordRejection: passwordRejection,
      hasStoredPassword: hasStoredPassword,
      saveError: saveError,
      onConnectionChanged: { Task { await refreshConnectionState() } }
    )
    if step.scrollsItself {
      stepView
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          stepView
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Brings the download into view the moment it is known to be needed.
        //
        // Keyed on the FACT rather than on the selection, because the tool's status arrives
        // on a stream a moment after the method is chosen, so scrolling on the click would
        // scroll before there was anything to say. Choosing a method whose program is
        // already installed scrolls nowhere, which is right: there is nothing down there to
        // do. `scrollTo` on an id that is not on screen is a no-op, so this is safe on every
        // other step.
        .onChange(of: progress.connection.toolMissing) { _, isMissing in
          guard isMissing else { return }
          withAnimation {
            proxy.scrollTo(OnboardingAnchor.requiredProgram, anchor: .top)
          }
        }
      }
    }
  }

  private var footer: some View {
    let gate = step.gate(progress)
    return VStack(alignment: .leading, spacing: 10) {
      // A read that failed, beside the button it may be holding shut, rather than on the
      // card of whichever step happens to be showing.
      if let problem = OnboardingRead.allCases.lazy.compactMap({ readProblems[$0] }).first {
        ErrorLine(problem)
      }
      if let message = gate.message {
        SettingsFootnote(
          text: message,
          symbol: gate.isOpen ? "info.circle" : "exclamationmark.triangle.fill",
          tone: gate.isOpen ? .attention : .problem
        )
      }
      HStack {
        // THE ONLY WAY OUT. This is a sheet, so it is modal to the window and the main
        // menu is disabled while it is up, which takes ⌘Q and the Quit menu item with it.
        // It terminates rather than dismissing: dismissing would drop the user into an app
        // whose server may have no password, which is the state the password gate exists
        // to prevent. The walkthrough returns on the next launch, because completion is
        // only recorded by finishing.
        Button("Quit") { quit() }
          .help("Quit BlueBubbles. Setup will start again next time you open it.")
        if !onboarding.isAtStart {
          Button("Back") { onboarding.back() }
        }
        Spacer()
        if step.isSkippable, !onboarding.isAtEnd {
          Button("Skip for now") { onboarding.advance() }
            .help("Come back to this any time from the sidebar.")
        }
        Button(onboarding.isAtEnd ? "Finish" : "Continue") {
          Task { await advance() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!gate.isOpen || (step.id == .goals && onboarding.selections.goals.isEmpty))
      }
    }
    .padding(24)
  }

  // MARK: - Gates

  private var unmetRequired: [Permission] {
    model.permissions.list.filter { permission in
      permission.requirement.isRequired
        && (model.permissions.statuses[permission.id] ?? .notDetermined) != .granted
    }
  }

  private var connectionManifest: ServiceManifest? {
    guard let id = onboarding.selections.connectionMethod else { return nil }
    return IntegrationCatalog.manifest(ServiceIdentifier(id))
  }

  /// The facts every gate decides on, read fresh from the model on each render.
  private var progress: OnboardingProgress {
    let tool = connectionManifest?.tools.first
    let toolStatus = tool.flatMap { model.toolStatus($0.id) }
    return OnboardingProgress(
      permissions: .init(
        unmetRequired: unmetRequired.map(\.title), acknowledgedSkip: acknowledgedSkip),
      connection: .init(
        passwordProblem: passwordRejection,
        requiresMethod: OnboardingRules.needsConnectionMethod(onboarding.selections.goals),
        method: onboarding.selections.connectionMethod,
        methodName: connectionManifest?.name,
        missingFields: missingConnectionFields.map(\.label),
        // nil status means the stream has not delivered one yet; assuming missing would
        // flash a warning on every appearance.
        toolMissing: tool != nil && toolStatus != nil && toolStatus?.executablePath == nil,
        toolName: tool?.displayName,
        acknowledgedToolSkip: acknowledgedToolSkip
      )
    )
  }

  /// Why the current password is unacceptable, or nil if it is fine.
  ///
  /// The SAME `PasswordPolicy` the settings write path runs, not a second opinion. A
  /// looser check here would let onboarding accept something the store then refuses, which
  /// is a dead end with no way forward.
  /// The decision itself is `OnboardingRules.passwordRejection`, so it can be tested: a
  /// `View` cannot be instantiated in a test process, and this rule is the one that decides
  /// whether re-running the assistant forces somebody to change a working password.
  private var passwordRejection: String? {
    OnboardingRules.passwordRejection(typed: password, hasStoredPassword: hasStoredPassword)
  }

  /// Copies the Private API answer into the plan. Followed by its `.task`, which the model
  /// moves on every write to the switch; a view never subscribes on its own.
  private func mirrorPrivateAPIState() async {
    do {
      onboarding.selections.messagesPrivateAPI = try await model.settings.get(
        Settings.enablePrivateAPI)
      readProblems[.privateAPI] = nil
    } catch {
      readProblems[.privateAPI] = DiagnosticText.sentence(for: error)
    }
  }

  /// Whether a password is already stored. Re-read after a write, so the card stops
  /// offering to keep one the moment a new one has replaced it.
  private func readStoredPassword() async {
    // `secret` returns nil when the Keychain could not be READ, which is not the same as
    // "there is none": answering false there would ask the person to set a new password
    // over one that exists and cannot be reached, and the write would land in the same
    // Keychain that just refused. Unreadable counts as present; the alert the store raises
    // is what says so.
    //
    // NOT `presence(of:)`, which the settings screen uses to avoid materialising a secret.
    // The question here is different: presence answers "is there a row", and this gate needs
    // "is there a USABLE password". A secret stored as the empty string is present and lets
    // nobody in, and a setup step that waved it through would finish with an open server.
    // The read is worth it for that, and it happens once.
    do {
      hasStoredPassword =
        try await model.settings.secret(Settings.password).map { !$0.isEmpty } ?? true
      readProblems[.storedPassword] = nil
    } catch {
      // No server, so nothing is known: the field is left asking, and the save that the
      // Continue button attempts says the same thing in its own words.
      readProblems[.storedPassword] = DiagnosticText.sentence(for: error)
    }
  }

  /// The port this server is actually on.
  ///
  /// See the property: this one is edited and written back, so it has to start from the
  /// stored value rather than from the setting's default.
  private func readConfiguredPort() async {
    do {
      port = try await model.settings.get(Settings.socketPort)
      readProblems[.port] = nil
    } catch {
      readProblems[.port] = DiagnosticText.sentence(for: error)
    }
  }

  /// Ticks the goals the server's own state already implies, once.
  ///
  /// The walkthrough runs after a migration as well as on a blank install, and after one it
  /// is reviewing a server that already has a password, a connection method, devices and
  /// webhooks. Everything else on these steps already reads through to the real value —
  /// the password card asks the Keychain, the connection step mirrors
  /// `IntegrationsModel`, the Private API and search switches are the generated rows over
  /// the same settings the rest of the app writes — and the goals step was the one place
  /// still starting from nothing.
  ///
  /// What may be inferred, and what deliberately may not, is
  /// `OnboardingRules.goalsImpliedByExistingState`; the counts are read here because that
  /// rule must stay testable without a server. A read that fails leaves the goals alone:
  /// an unticked box is a question, and a wrong tick is an answer.
  private func seedGoalsFromServer() async {
    guard onboarding.selections.hasSeededGoalsFromServer != true else { return }
    guard model.phase.isRunning else { return }

    let devices = (try? await model.delivery.pushDevices?.all().count) ?? nil
    let webhooks = await model.delivery.webhooks?.targets().count
    // `hasServiceAccount`, not `isConfigured`: the key alone is what lets this server
    // republish its address, which is the half of Firebase a desktop client uses. A server
    // with a key and no `google-services.json` still does that. See `PushStatus`.
    let firebase = await model.delivery.push?.pushInterface().status().hasServiceAccount

    onboarding.selections.goals.formUnion(
      OnboardingRules.goalsImpliedByExistingState(
        pushDevices: devices ?? 0, webhooks: webhooks ?? 0,
        firebaseConfigured: firebase ?? false))
    onboarding.selections.hasSeededGoalsFromServer = true
  }

  /// Takes the sheet down, then quits on the next run-loop turn; see
  /// `AppTermination.quitFromSheet` for why a sheet cannot quit directly.
  ///
  /// Dismissing first costs one run-loop turn in which the main window is visible behind a
  /// server that may have no password — the state the comment on the button warns about.
  /// One turn is the price of the button working at all, and the process is gone by the
  /// next one. Setting `isPresented` does not re-arm the walkthrough: `RootView` presents
  /// it from a `.task(id:)` on the server phase, which does not change here.
  private func quit() {
    // `debug`: one line per unit of work, and the one that says a person pressed the
    // button at all. Without it, "Quit did nothing" and "Quit was never pressed" are the
    // same silence — which is exactly the ambiguity this bug was hiding in.
    Logger(label: "bluebubbles.app").debug("Quit pressed during setup")
    AppTermination.quitFromSheet { onboarding.isPresented = false }
  }

  /// What the connection step's `.task` is keyed on: the chosen method, and how often its
  /// settings have moved.
  private struct ConnectionKey: Equatable {
    let method: String?
    let version: UInt64
  }

  /// Moves on every write to the chosen method's own settings.
  ///
  /// **A read keyed on the connection method alone cannot see a FIELD being filled in.**
  /// The gate would go on saying "Address is required" over an address the person had just
  /// saved, and the step could not be passed: choosing another method and coming back is
  /// the only way to re-seed it, which nobody would guess.
  ///
  /// The step's own form (`ServiceFormView`) writes these keys, and nothing tells this
  /// view. Threading a callback out of the form would work for the form and still miss the
  /// settings screen, the API and `--set`, all of which write the same keys. So the model
  /// follows them (`SettingsModel.version(inNamespace:)`) — live state is followed, never
  /// polled, and never subscribed to by a view — and the `.task` reads again when it moves.
  /// Matched on the manifest's own namespace rather than a list of its fields, so a method
  /// gaining a required field needs no change here.
  private var connectionVersion: UInt64 {
    guard let manifest = connectionManifest else { return 0 }
    return model.settings.version(inNamespace: manifest.id.rawValue + ".")
  }

  /// One read, also for a caller that needs the answer now rather than on the next change:
  /// the Continue button checks the gate against it before advancing.
  private func refreshConnectionState() async {
    guard let manifest = connectionManifest else {
      missingConnectionFields = []
      return
    }
    do {
      missingConnectionFields = try await model.settings.missingRequiredFields(manifest)
      readProblems[.connectionFields] = nil
    } catch {
      missingConnectionFields = []
      readProblems[.connectionFields] = DiagnosticText.sentence(for: error)
    }
  }

  // MARK: - Moving on

  private func advance() async {
    if step.id == .connection {
      // Saved on the way out of the step rather than by a button inside it. A password
      // that was typed and not saved is indistinguishable, on every later screen, from
      // one that was never set.
      guard await saveCredentials() else { return }
      // Re-checked at the moment of leaving, not only from the last render: the service
      // form inside the step saves on focus loss, and the Continue click is what blurs it.
      await refreshConnectionState()
      guard step.gate(progress).isOpen else { return }
    }

    guard !onboarding.isAtEnd else {
      // Recorded, so a later support conversation can establish that the user chose to
      // proceed without a required permission rather than never being asked.
      if !unmetRequired.isEmpty {
        model.permissions.recordOnboardingSkip(unmetRequired.map(\.id.rawValue))
      }
      onboarding.complete()
      return
    }
    onboarding.advance()
  }

  /// Writes the password and port. Returns false if the store refused, leaving the step up.
  private func saveCredentials() async -> Bool {
    do {
      // NOT written when the field is empty and one is already stored. Writing "" there
      // would clear a working password on the way past a step the person had no reason to
      // touch, and `PasswordPolicy` exempts the empty string (it is the shipped default) so
      // nothing below would have refused it.
      if !password.isEmpty {
        try await model.settings.set(Settings.password, to: password)
      }
      // Only written when it was asked; a port the person never saw keeps its value.
      if OnboardingRules.asksForPort(onboarding.selections.goals) {
        try await model.settings.set(Settings.socketPort, to: port)
      }
      saveError = nil
      await readStoredPassword()
      return true
    } catch {
      // The store's own words. Its validator has a specific reason and it is more useful
      // than "invalid", and more useful still than the raw enum a generic catch renders.
      saveError = DiagnosticText.sentence(for: error)
      return false
    }
  }
}

/// The reads the walkthrough makes of the server, each with its own failure slot.
private enum OnboardingRead: CaseIterable {
  case storedPassword
  case port
  case connectionFields
  case privateAPI
}
