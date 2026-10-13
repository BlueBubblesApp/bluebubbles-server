//  OnboardingSteps
//  One view per step, each built from the screens the app already has.
//
//  Nothing here is a second copy of a settings control. The permission rows, the generated
//  setting rows, the service form, the tool installer, the Firebase page and the webhooks
//  page are the same views the sidebar reaches: embedded, so setup and settings cannot drift
//  apart. What this file adds is the framing: why the person is looking at it, and what to
//  do with it now.
//
//  The switch in `OnboardingStepView` is exhaustive over `OnboardingStep.ID`. A step added
//  to the catalogue without a view here does not compile.

import BBCore
import BBServiceKit
import BBSettings
import BBSystem
import BlueBubblesServerCore
import SwiftUI

/// Places inside a step that something outside it has to be able to scroll to.
///
/// A string rather than a view's static, because `OnboardingView` owns the `ScrollView` and
/// the step that draws the target is private to this file.
enum OnboardingAnchor {
  /// The managed-program panel on the connection step.
  ///
  /// The whole complaint behind this was that the download button exists and nobody could
  /// see it: the password card and a grid of six methods put it below the fold, and the
  /// footer said the program was missing without saying there was anywhere to go. The gate
  /// now blocks on it, which is what makes someone look; this is what means they do not
  /// have to look far.
  static let requiredProgram = "onboarding.connection.requiredProgram"
}

struct OnboardingStepView: View {
  let step: OnboardingStep.ID
  @Bindable var model: AppModel
  @Binding var password: String
  @Binding var port: Int
  @Binding var acknowledgedSkip: Bool
  @Binding var acknowledgedToolSkip: Bool
  let passwordRejection: String?
  let hasStoredPassword: Bool
  let saveError: String?
  let onConnectionChanged: () -> Void

  var body: some View {
    switch step {
    case .welcome: WelcomeStep()
    case .goals: GoalsStep(onboarding: model.onboarding)
    case .permissions: PermissionsStep(model: model, acknowledgedSkip: $acknowledgedSkip)
    case .connection:
      ConnectionStepView(
        model: model, password: $password, port: $port,
        acknowledgedToolSkip: $acknowledgedToolSkip,
        passwordRejection: passwordRejection, hasStoredPassword: hasStoredPassword,
        saveError: saveError, onChanged: onConnectionChanged)
    case .firebase: FirebaseStep(model: model)
    case .webhooks: WebhooksView(model: model)
    case .api: APIStep(model: model)
    case .privateAPI: PrivateAPIStep(model: model)
    case .search: SearchStep(model: model)
    case .groupShortcut: GroupShortcutStep(model: model)
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
          DividedForEach(model.permissions.list) { permission in
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
    // Setup is the other place status has to be live: the whole step is the user leaving
    // for System Settings and coming back to check.
    .permissionsLiveUpdates(model.permissions)
  }
}

// MARK: - Connection

/// Password first, then (when something will connect) how it reaches this Mac.
private struct ConnectionStepView: View {
  @Bindable var model: AppModel
  @Binding var password: String
  @Binding var port: Int
  @Binding var acknowledgedToolSkip: Bool
  let passwordRejection: String?
  let hasStoredPassword: Bool
  let saveError: String?
  let onChanged: () -> Void

  private var goals: Set<UsageGoal> { model.onboarding.selections.goals }

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      PasswordCard(
        password: $password, port: $port,
        rejection: passwordRejection, saveError: saveError,
        hasStoredPassword: hasStoredPassword,
        showsPort: OnboardingRules.asksForPort(goals))
      if OnboardingRules.needsConnectionMethod(goals) {
        Text("How will clients reach this Mac?")
          .font(.title3.weight(.semibold))
        ConnectionMethodPicker(
          model: model, acknowledgedToolSkip: $acknowledgedToolSkip, onChanged: onChanged)
      }
    }
  }
}

private struct ConnectionMethodPicker: View {
  @Bindable var model: AppModel
  @Binding var acknowledgedToolSkip: Bool
  let onChanged: () -> Void

  private var manifests: [ServiceManifest] {
    ConnectionMethodChoices.available().compactMap { choice in
      IntegrationCatalog.manifest(ServiceIdentifier(choice.value))
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
            title: ConnectionMethodChoices.label(for: manifest),
            summary: manifest.summary,
            symbol: manifest.symbol,
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
            .id(OnboardingAnchor.requiredProgram)
          // The same acknowledgement the permissions step offers, and for the same reason:
          // the download can fail for something the person cannot fix right now, and this
          // step has no Skip. Shown only while the program is actually absent, so a Mac
          // that already has it never meets the question.
          if model.toolStatus(tool.id)?.executablePath == nil,
            model.toolStatus(tool.id) != nil
          {
            Toggle(isOn: $acknowledgedToolSkip) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Set \(tool.displayName) up later")
                Text(
                  "I understand nothing will be able to reach this Mac until it is installed."
                )
                .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        if !selected.settings.isEmpty {
          ServiceFormView(manifest: selected, model: model)
        }
        // And what it produced, so the step ends with the address rather than a form.
        PublishedAddressSection(manifest: selected, model: model)
      }
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
      // credential files: all of it happens here exactly as it does from the sidebar.
      FirebaseView(model: model)
    }
  }
}

// MARK: - API

private struct APIStep: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GlassCard {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardStackSpacing) {
          ServerAddressRow(model: model, label: "Base URL")
          LabeledContent("Local port") {
            Text(model.clientAddress.port.map(String.init) ?? "-").font(.body.monospaced())
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
  }
}

// MARK: - Private API

/// The message search index: one switch, and enough plain language to weigh it.
///
/// **The copy is the feature here.** What is being asked for is permission to derive a word
/// list from every message and keep it on disk, and somebody agreeing to that should know
/// what it is, where it goes, and how to undo it — in words that do not require knowing what
/// an index is. So: no "full-text index", no "FTS5", no "tokenised". "A word list, not your
/// conversations" is the same fact in terms a person can actually weigh.
///
/// The last paragraph states the cost of DECLINING in the same register as the benefit of
/// accepting. A step that only lists upsides is a consent screen that has already decided.
private struct SearchStep: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if model.settings.isAvailable {
        // The generated row, not a `Toggle` of its own: the same control the Features
        // settings page draws, from the same declaration, so the two cannot disagree about
        // the label, the help text or what writing it does.
        GlassCard {
          SettingRow(setting: Settings.searchIndexEnabled.erased, model: model)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        Self.paragraph(
          "What it does",
          "BlueBubbles reads your message history once and notes which words appear in which "
            + "message. It takes about a minute and happens entirely on this Mac.")
        Self.paragraph(
          "What gets stored",
          "A word list, not your conversations. The index can answer \u{201C}message 4,182 "
            + "contains the word dinner\u{201D}. It does not keep the message.")
        Self.paragraph(
          "Where it lives",
          "In BlueBubbles\u{2019} own folder on this Mac, readable only by your account. "
            + "Nothing is uploaded, and turning this off deletes it.")
        Self.paragraph(
          "If you leave it off",
          "Everything else works exactly the same. Searching message text will keep missing "
            + "anything sent since your Mac updated.")
      }
      .padding(.horizontal, 2)
    }
  }

  /// A labelled paragraph. Combined into one accessibility element, because a heading and
  /// its sentence are one thing to read and two stops is two stops too many.
  @ViewBuilder
  private static func paragraph(_ heading: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(heading).font(.subheadline).fontWeight(.semibold)
      Text(body).font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct PrivateAPIStep: View {
  @Bindable var model: AppModel

  private var sipDisabled: Bool {
    (model.permissions.statuses[.systemIntegrityProtection] ?? .notDetermined) == .granted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if sipDisabled {
        PrivateAPIStatusCard(model: model)
        if model.settings.isAvailable {
          // ONE card, and no section headers: unlike the settings tab, which needs them
          // because it is a page someone browses. Here the step's own title and purpose
          // sentence are directly above, and the sentence already says what Messages and
          // FaceTime each get. "Messages" and "FaceTime" headers with subtitles repeating
          // that sentence put roughly ninety points of restatement between the heading and
          // the first switch, which makes the toggles look stranded.
          //
          // The rows carry the grouping themselves, being named for their apps
          // ("Messages Private API", "FaceTime Private API") and they are still the same
          // `SettingRow` the settings tab draws, from the same declarations.
          //
          // All three, because Messages and FaceTime are two independent capabilities in
          // two different apps: `PrivateAPIGatedService.canRun()` starts on EITHER, and
          // FaceTime does not need the Messages helper. Hand-off rides with the switch it
          // depends on rather than waiting for a Settings visit: it is the FaceTime
          // capability a client actually uses. Registry order throughout.
          GlassCard {
            VStack(alignment: .leading, spacing: 0) {
              DividedForEach(Self.toggles) { setting in
                SettingRow(setting: setting, model: model)
              }
            }
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

  /// What this step switches on, in the order the settings tab shows them.
  ///
  /// The declarations, not copies of them: the label, the help sentence and the control all
  /// come from `SettingsRegistry`, so this screen cannot end up calling a switch something
  /// the settings page does not.
  private static let toggles: [AnySetting] = [
    Settings.enablePrivateAPI.erased,
    Settings.enableFaceTimePrivateAPI.erased,
    Settings.faceTimeIncomingHandoff.erased,
    // The one row that answers "what does this do to my Mac". Turning the FaceTime Private
    // API on keeps FaceTime.app running, and FaceTime shows your camera when it is open;
    // this is what stops that meaning a camera that is on all day. It defaults ON, so the
    // row is here to be SEEN rather than to be switched: somebody who wants FaceTime.app
    // untouched needs to know the switch exists.
    Settings.faceTimeOutgoingCalls.erased,
    Settings.faceTimeIdleCameraOff.erased,
  ]
}

// MARK: - Group chat Shortcut

private struct GroupShortcutStep: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "Two clicks, both of which macOS insists a person makes: confirm the Shortcut when "
          + "the Shortcuts app asks, then send one test message and choose **Always "
          + "Allow** when prompted. That grant is what lets the server create groups "
          + "from then on."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      // The same panel Settings › General shows when the Private API is off.
      GroupChatShortcutSection(model: model)
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
        .foregroundStyle(StatusTone.good.tint)
        .font(.headline)

      if !model.onboarding.selections.goals.isEmpty {
        TitledCard("Set up for") {
          ForEach(UsageGoal.allCases.filter { model.onboarding.selections.goals.contains($0) }) {
            goal in
            Label(goal.title, systemImage: goal.symbol).font(.callout)
          }
          Text("Anything needing attention will show up under the bell at the top right.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      if model.settings.isAvailable {
        // Rendered by the same rows the settings screen uses, from a list in the
        // catalogue: adding a preference here is adding a key there.
        SettingsSection("Preferences", subtitle: "Changeable later under Settings › General.") {
          DividedForEach(settings) { setting in
            SettingRow(setting: setting, model: model)
          }
        }
      }
    }
  }
}
