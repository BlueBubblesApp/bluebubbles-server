//  OnboardingSteps
//  One view per step, each built from the screens the app already has.
//
//  Nothing here is a second copy of a settings control. The permission rows, the generated
//  setting rows, the service form, the tool installer, the Firebase page and the webhooks
//  page are the same views the sidebar reaches — embedded, so setup and settings cannot drift
//  apart. What this file adds is the framing: why the person is looking at it, and what to
//  do with it now.
//
//  The switch in `OnboardingStepView` is exhaustive over `OnboardingStep.ID`. A step added
//  to the catalogue without a view here does not compile.

import BBServiceKit
import BBSettings
import BBSystem
import BlueBubblesServerCore
import SwiftUI

struct OnboardingStepView: View {
  let step: OnboardingStep.ID
  @Bindable var model: AppModel
  @Binding var password: String
  @Binding var port: Int
  @Binding var acknowledgedSkip: Bool
  let passwordRejection: String?
  let connectionError: String?
  let onConnectionChanged: () -> Void

  var body: some View {
    switch step {
    case .welcome: WelcomeStep()
    case .goals: GoalsStep(onboarding: model.onboarding)
    case .permissions: PermissionsStep(model: model, acknowledgedSkip: $acknowledgedSkip)
    case .password:
      ConnectionStep(
        model: model, password: $password, port: $port,
        rejection: passwordRejection, saveError: connectionError,
        showsPort: OnboardingRules.asksForPort(model.onboarding.selections.goals))
    case .connection: ConnectionMethodStep(model: model, onChanged: onConnectionChanged)
    case .firebase: FirebaseStep(model: model)
    case .webhooks: WebhooksView(model: model)
    case .api: APIStep(model: model)
    case .privateAPI: PrivateAPIStep(model: model)
    case .finish: FinishStep(model: model)
    }
  }
}

// MARK: - Welcome

private struct WelcomeStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        "Setup takes a couple of minutes. It starts by asking what you want to use the "
          + "server for, and only walks you through the parts that matter for that."
      )
      Text(
        "Everything here can be changed later in Settings, and you can run this "
          + "walkthrough again from the BlueBubbles menu."
      )
      .foregroundStyle(.secondary)
      // Said up front rather than discovered later. Someone who does not want to
      // disable SIP should know now that they do not have to.
      Label(
        "The server runs without disabling System Integrity Protection. Some features "
          + "need it; sending and receiving do not.",
        systemImage: "info.circle"
      )
      .font(.callout)
      .padding(.top, 4)
    }
  }
}

// MARK: - Goals

private struct GoalsStep: View {
  @Bindable var onboarding: OnboardingModel

  var body: some View {
    ChoiceGrid {
      ForEach(UsageGoal.allCases) { goal in
        ChoiceCard(
          title: goal.title,
          summary: goal.summary,
          symbol: goal.symbol,
          isSelected: onboarding.selections.goals.contains(goal),
          isMultiSelect: true
        ) {
          if onboarding.selections.goals.contains(goal) {
            onboarding.selections.goals.remove(goal)
          } else {
            onboarding.selections.goals.insert(goal)
          }
        }
      }
    }
  }
}

// MARK: - Permissions

private struct PermissionsStep: View {
  @Bindable var model: AppModel
  @Binding var acknowledgedSkip: Bool

  private var unmetRequired: [Permission] {
    model.permissions.list.filter { permission in
      permission.requirement.isRequired
        && (model.permissions.statuses[permission.id] ?? .notDetermined) != .granted
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Grant these now. Status updates as you change them in System Settings.")
        .foregroundStyle(.secondary)

      GlassCard {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(model.permissions.list.enumerated()), id: \.element.id) {
            index, permission in
            if index > 0 { SettingsDivider() }
            PermissionRow(
              permission: permission,
              status: model.permissions.statuses[permission.id] ?? .notDetermined,
              model: model
            )
          }
        }
      }

      if !unmetRequired.isEmpty {
        Toggle(isOn: $acknowledgedSkip) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Continue without \(unmetRequired.map(\.title).joined(separator: ", "))")
            Text("I understand the features that need them will not work.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.top, 8)
      }
    }
  }
}

// MARK: - Connection method

private struct ConnectionMethodStep: View {
  @Bindable var model: AppModel
  let onChanged: () -> Void

  private var manifests: [ServiceManifest] {
    ConnectionMethodChoices.available().compactMap { choice in
      BuiltInManifests.all.first { $0.id.rawValue == choice.value }
    }
  }

  private var selected: ServiceManifest? {
    manifests.first { $0.id.rawValue == model.integrations.selectedConnectionMethod }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      ChoiceGrid {
        ForEach(manifests, id: \.id) { manifest in
          ChoiceCard(
            title: manifest.name,
            summary: manifest.summary,
            symbol: Self.symbol(for: manifest),
            isSelected: manifest.id == selected?.id,
            isMultiSelect: false
          ) {
            Task {
              await model.integrations.select(manifest)
              onChanged()
            }
          }
        }
      }

      if let selected {
        // Everything the chosen method still needs, right here: the program it runs and
        // the fields it reads. These are the service's own panels, not a summary of them.
        if let tool = selected.tools.first {
          ManagedToolSection(descriptor: tool, model: model)
        }
        if !selected.settings.isEmpty, let store = model.settingsStore {
          ServiceFormView(manifest: selected, store: store, model: model)
        }
      }
    }
    // Followed rather than read once: an install runs for tens of seconds, and a step that
    // sampled the status would show "not downloaded" for all of it.
    .task { model.beginObservingTools() }
    .onDisappear { model.endObservingTools() }
  }

  /// A recognisable glyph per method. Falls back to a generic one for a method this file
  /// has not met, so a third-party tunnel still gets a card.
  private static func symbol(for manifest: ServiceManifest) -> String {
    switch manifest.id {
    case BuiltInManifests.ID.proxyLAN: "wifi"
    case BuiltInManifests.ID.proxyDynamicDNS: "globe"
    case BuiltInManifests.ID.proxyCloudflare: "cloud"
    case BuiltInManifests.ID.proxyNgrok: "point.3.connected.trianglepath.dotted"
    case BuiltInManifests.ID.proxyZrok: "bolt.horizontal"
    default: "network"
    }
  }
}

// MARK: - Firebase

private struct FirebaseStep: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      if let role = OnboardingRules.firebaseRole(for: model.onboarding.selections) {
        HStack(spacing: 10) {
          Image(systemName: "bell.badge").foregroundStyle(Color.accentColor)
          Text("What Firebase is for here: **\(role.title)**.")
            .font(.callout)
          Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        Divider()
      }
      // The page itself, not a summary of it. Signing in, choosing a project, dropping the
      // credential files — all of it happens here exactly as it does from the sidebar.
      FirebaseView(model: model)
    }
  }
}

// MARK: - API

private struct APIStep: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @State private var address = "—"
  @State private var port = 1234

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GlassCard {
        VStack(alignment: .leading, spacing: 12) {
          LabeledContent("Base URL") {
            Text(address).textSelection(.enabled).font(.body.monospaced())
          }
          LabeledContent("Local port") {
            Text(String(port)).font(.body.monospaced())
          }
          LabeledContent("Authentication") {
            Text("Add the server password as the `password` query parameter or header.")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      HStack(spacing: 12) {
        Button("Open API Reference") { openWindow(id: APIDocsView.windowID) }
          .buttonStyle(.borderedProminent)
        Link(
          "Read the docs",
          destination: URL(string: "https://docs.bluebubbles.app/server/")!)
      }
      Text(
        "The reference is generated from this server, so it describes exactly the routes "
          + "and fields this version answers with."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .task {
      guard let store = model.settingsStore else { return }
      port = await store.get(Settings.socketPort)
      let configured = await store.get(Settings.serverAddress)
      address = configured.isEmpty ? "http://localhost:\(port)" : configured
    }
  }
}

// MARK: - Private API

private struct PrivateAPIStep: View {
  @Bindable var model: AppModel

  private var sipDisabled: Bool {
    (model.permissions.statuses[.systemIntegrityProtection] ?? .notDetermined) == .granted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if sipDisabled {
        PrivateAPIStatusCard(model: model)
        if let store = model.settingsStore {
          // The same toggle the Private API settings tab shows.
          SettingsSection("Messages") {
            SettingRow(setting: Settings.enablePrivateAPI.erased, store: store)
          }
        }
      } else {
        PrivateAPIPrerequisiteNote()
        Text(
          "Nothing is broken. Sending, receiving, attachments, contacts and notifications "
            + "all work without it. Skip this, or come back to it under Settings › "
            + "Private API once SIP is disabled."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Finish

private struct FinishStep: View {
  @Bindable var model: AppModel

  private var settings: [AnySetting] {
    OnboardingCatalog.finishSettingKeys.compactMap { key in
      Settings.all.first { $0.key == key }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("The server is running.", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.headline)

      if !model.onboarding.selections.goals.isEmpty {
        GlassCard {
          VStack(alignment: .leading, spacing: 8) {
            Text("Set up for").font(.subheadline.weight(.semibold))
            ForEach(UsageGoal.allCases.filter { model.onboarding.selections.goals.contains($0) }) {
              goal in
              Label(goal.title, systemImage: goal.symbol).font(.callout)
            }
            Text("Anything needing attention will show up under the bell at the top right.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .padding(.top, 4)
          }
        }
      }

      if let store = model.settingsStore {
        // Rendered by the same rows the settings screen uses, from a list in the
        // catalogue: adding a preference here is adding a key there.
        SettingsSection("Preferences", subtitle: "Changeable later under Settings › General.") {
          ForEach(Array(settings.enumerated()), id: \.element.id) { index, setting in
            if index > 0 { SettingsDivider() }
            SettingRow(setting: setting, store: store)
          }
        }
      }
    }
  }
}
