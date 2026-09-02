//  OnboardingView
//  The setup walkthrough: a rail of steps, the current step, and the way forward.
//
//  What is asked and in what order comes from `OnboardingCatalog` via `OnboardingModel`;
//  this file is the shell. It owns exactly the state a gate has to be certain of — the typed
//  password, and whether the permission skip was acknowledged — and builds the
//  `OnboardingProgress` a step's gate decides on.
//
//  See `Onboarding/OnboardingFlow.swift` for the rules and `.claude/docs/architecture.md`.

import BBServiceKit
import BBSettings
import BBSystem
import BlueBubblesServerCore
import SwiftUI

struct OnboardingView: View {

  @Bindable var model: AppModel

  @State private var acknowledgedSkip = false
  // Owned HERE rather than inside the password step, because the Continue button has to be
  // able to both refuse to advance on a bad password and persist a good one. While the step
  // owned them, it could only offer a Save button of its own — and skipping that button was
  // exactly how a server ended up with no password at all.
  @State private var password = ""
  @State private var port = 1234
  @State private var connectionError: String?
  @State private var missingConnectionFields: [FieldDescriptor] = []

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
    .frame(width: 900, height: 640)
    .task { await model.permissions.refresh() }
    .task(id: onboarding.selections.connectionMethod) { await refreshConnectionState() }
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
          .foregroundStyle(isDone ? Color.green : isCurrent ? Color.accentColor : .secondary)
          .frame(width: 20)
        Text(entry.title)
          .font(isCurrent ? .body.weight(.semibold) : .body)
          .foregroundStyle(isCurrent || isDone ? .primary : .secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
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
      passwordRejection: passwordRejection,
      connectionError: connectionError,
      onConnectionChanged: { Task { await refreshConnectionState() } }
    )
    if step.scrollsItself {
      stepView
    } else {
      ScrollView {
        stepView
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var footer: some View {
    let gate = step.gate(progress)
    return VStack(alignment: .leading, spacing: 10) {
      if let message = gate.message {
        SettingsFootnote(
          text: message,
          symbol: gate.isOpen ? "info.circle" : "exclamationmark.triangle.fill",
          tone: gate.isOpen ? .warning : .error
        )
      }
      HStack {
        // THE ONLY WAY OUT. This is a sheet, so it is modal to the window and the main
        // menu is disabled while it is up — which takes ⌘Q and the Quit menu item with it.
        // It terminates rather than dismissing: dismissing would drop the user into an app
        // whose server may have no password, which is the state the password gate exists
        // to prevent. The walkthrough returns on the next launch, because completion is
        // only recorded by finishing.
        Button("Quit") { NSApplication.shared.terminate(nil) }
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
    return BuiltInManifests.all.first { $0.id.rawValue == id }
  }

  /// The facts every gate decides on, read fresh from the model on each render.
  private var progress: OnboardingProgress {
    let tool = connectionManifest?.tools.first
    let toolStatus = tool.flatMap { model.toolStatus($0.id) }
    return OnboardingProgress(
      unmetRequiredPermissions: unmetRequired.map(\.title),
      acknowledgedPermissionSkip: acknowledgedSkip,
      passwordProblem: passwordRejection,
      connectionMethod: onboarding.selections.connectionMethod,
      connectionMethodName: connectionManifest?.name,
      missingConnectionFields: missingConnectionFields.map(\.label),
      // nil status means the stream has not delivered one yet; assuming missing would flash
      // a warning on every appearance.
      connectionToolMissing: tool != nil && toolStatus != nil && toolStatus?.executablePath == nil,
      connectionToolName: tool?.displayName
    )
  }

  /// Why the current password is unacceptable, or nil if it is fine.
  ///
  /// The SAME `PasswordPolicy` the settings write path runs, not a second opinion. A
  /// looser check here would let onboarding accept something the store then refuses, which
  /// is a dead end with no way forward.
  private var passwordRejection: String? {
    guard !password.isEmpty else { return "" }
    do {
      try PasswordPolicy().validate(password)
      return nil
    } catch let rejection as PasswordPolicy.Rejection {
      return rejection.userMessage
    } catch {
      return String(describing: error)
    }
  }

  private func refreshConnectionState() async {
    guard let manifest = connectionManifest, let store = model.settingsStore else {
      missingConnectionFields = []
      return
    }
    missingConnectionFields = await ServiceSettingsBridge.missingRequiredFields(
      manifest, store: store)
  }

  // MARK: - Moving on

  private func advance() async {
    switch step.id {
    case .password:
      // Saved on the way out of the step rather than by a button inside it. A password
      // that was typed and not saved is indistinguishable, on every later screen, from
      // one that was never set.
      guard await saveConnection() else { return }
    case .connection:
      // Re-checked at the moment of leaving, not only from the last render: the form
      // inside the step saves on focus loss, and the Continue click is what blurs it.
      await refreshConnectionState()
      guard step.gate(progress).isOpen else { return }
    default:
      break
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
  private func saveConnection() async -> Bool {
    guard let store = model.settingsStore else {
      connectionError = "Settings are not available yet. Try again in a moment."
      return false
    }
    do {
      try await store.set(Settings.password, to: password)
      // Only written when it was asked; a port the person never saw keeps its value.
      if OnboardingRules.asksForPort(onboarding.selections.goals) {
        try await store.set(Settings.socketPort, to: port)
      }
      connectionError = nil
      return true
    } catch {
      // The store's own words. Its validator has a specific reason and it is more useful
      // than "invalid" — and more useful still than the raw enum a generic catch renders.
      connectionError = userFacingMessage(error)
      return false
    }
  }
}
