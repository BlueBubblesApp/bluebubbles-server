//  OnboardingView
//  The first-run walkthrough.
//
//  Intro → Permissions → Connection → Private API → Done.
//
//  The permission step GATES. Today it is possible to sail through setup and discover much
//  later that a permission was never granted — which is the exact failure the user described:
//  a permission that wasn't set up front becomes a mysterious failure later. Here, advancing
//  past unmet required permissions takes an explicit "skip — I understand these features
//  won't work", and that acknowledgement is recorded.
//
//  See `.claude/docs/architecture.md` and `docs/AUTH.md`.

import BBSettings
import BBSystem
import SwiftUI

struct OnboardingView: View {

  @Bindable var model: AppModel
  @Binding var isPresented: Bool

  @State private var step: Step = .intro
  @State private var acknowledgedSkip = false
  // Owned HERE rather than inside ConnectionStep, because the Continue button has to be
  // able to both refuse to advance on a bad password and persist a good one. While the step
  // owned them, it could only offer a Save button of its own — and skipping that button was
  // exactly how a server ended up with no password at all.
  @State private var password = ""
  @State private var port = 1234
  @State private var connectionError: String?
  @State private var startAtLogin = false
  @State private var checkForUpdates = false
  @Environment(\.openURL) private var openURL

  enum Step: Int, CaseIterable {
    case intro, permissions, connection, privateAPI, done

    var title: String {
      switch self {
      case .intro: "Welcome to BlueBubbles"
      case .permissions: "Permissions"
      case .connection: "Connection"
      case .privateAPI: "Private API"
      case .done: "You're set up"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView { body(for: step).padding(24) }
      Divider()
      footer
    }
    .frame(width: 620, height: 560)
    .task { await model.refreshPermissions() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(step.title).font(.title2.weight(.semibold))
      ProgressView(
        value: Double(step.rawValue),
        total: Double(Step.allCases.count - 1)
      )
    }
    .padding(24)
  }

  @ViewBuilder
  private func body(for step: Step) -> some View {
    switch step {
    case .intro:
      VStack(alignment: .leading, spacing: 12) {
        Text("BlueBubbles gives your other devices access to iMessage on this Mac.")
        Text(
          "Setup takes a couple of minutes. The next screen covers the macOS "
            + "permissions the server needs, and explains what each one is for."
        )
        .foregroundStyle(.secondary)
        // Said up front rather than discovered later. Someone who does not want to
        // disable SIP should know now that they do not have to.
        Label(
          "The server runs without disabling System Integrity Protection. Some "
            + "features need it; sending and receiving do not.",
          systemImage: "info.circle"
        )
        .font(.callout)
        .padding(.top, 8)
      }

    case .permissions:
      VStack(alignment: .leading, spacing: 12) {
        Text("Grant these now. Status updates as you change them in System Settings.")
          .foregroundStyle(.secondary)

        // One card around the list, because `PermissionRow` stopped carrying its own
        // — it is a row inside a settings card now, and a bare stack of them here
        // would float on the onboarding sheet with no surface under it.
        GlassCard {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.permissionList.enumerated()), id: \.element.id) {
              index, permission in
              if index > 0 { SettingsDivider() }
              PermissionRow(
                permission: permission,
                status: model.permissions[permission.id] ?? .notDetermined,
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

    case .connection:
      ConnectionStep(
        model: model, password: $password, port: $port,
        rejection: passwordRejection, saveError: connectionError)

    case .privateAPI:
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "The Private API adds reactions, editing and unsending, typing "
            + "indicators, and group management.")
        Text(
          "It works by loading a helper inside Messages, which requires System "
            + "Integrity Protection to be disabled. That is a real trade-off and "
            + "it is your call."
        )
        .foregroundStyle(.secondary)

        let sipStatus = model.permissions[.systemIntegrityProtection] ?? .notDetermined
        StatusDot(
          level: sipStatus == .granted ? .ok : .unknown,
          label: sipStatus == .granted
            ? "SIP is disabled — the Private API can be enabled"
            : "SIP is enabled — the Private API is unavailable"
        )

        if sipStatus != .granted {
          Text(
            "Nothing is broken. Sending, receiving, attachments, contacts and "
              + "notifications all work without it."
          )
          .font(.callout)
          .padding(.top, 4)
        }
      }

    case .done:
      VStack(alignment: .leading, spacing: 16) {
        Label("The server is running.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.headline)
        Text(
          "Point a BlueBubbles client at the address on the API & Webhooks page. "
            + "Anything needing attention will show up under the bell at the top "
            + "right."
        )
        .foregroundStyle(.secondary)

        Divider()

        // Asked here rather than left to be discovered in settings. A message server
        // that does not come back after a reboot is a server that quietly stops
        // working, and the moment someone is deciding to keep it is the moment to
        // ask. Off unless they say yes — nothing registers a login item silently.
        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: $startAtLogin) {
            Text("Start BlueBubbles when I log in").font(.body)
          }
          .toggleStyle(.switch)
          .onChange(of: startAtLogin) { _, enabled in
            Task { await saveStartAtLogin(enabled) }
          }
          Text(
            "Recommended. Without this the server only runs while you have the "
              + "app open. You can change it later under Settings › General."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: $checkForUpdates) {
            Text("Check for updates automatically").font(.body)
          }
          .toggleStyle(.switch)
          .onChange(of: checkForUpdates) { _, enabled in
            Task { await saveCheckForUpdates(enabled) }
          }
          // Off unless asked. This is the app reaching out to the network on a
          // schedule the user did not choose, which is a thing to opt into rather
          // than out of — and the menu item works either way.
          Text(
            "Looks for a new release once a day. You can always check by hand "
              + "from the BlueBubbles menu."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .task { await loadFinishStep() }
    }
  }

  private var footer: some View {
    HStack {
      // THE ONLY WAY OUT. This is a sheet, so it is modal to the window and the main menu
      // is disabled while it is up — which takes ⌘Q and the Quit menu item with it. Without
      // a button here, someone who opened the app and did not want to set it up right now
      // had no way to leave except killing the process.
      //
      // It terminates rather than dismissing the sheet. Dismissing would drop the user into
      // an app whose server has no password, which is the state the connection gate exists
      // to prevent; quitting leaves nothing half-configured and the walkthrough returns on
      // the next launch, because `hasCompletedOnboarding` is only set by finishing.
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .help("Quit BlueBubbles. Setup will start again next time you open it.")

      if step != .intro {
        Button("Back") {
          step = Step(rawValue: step.rawValue - 1) ?? .intro
        }
      }
      Spacer()
      Button(step == .done ? "Finish" : "Continue") {
        Task { await advance() }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!canAdvance)
    }
    .padding(24)
  }

  private var unmetRequired: [Permission] {
    model.permissionList.filter { permission in
      permission.requirement.isRequired
        && (model.permissions[permission.id] ?? .notDetermined) != .granted
    }
  }

  private func loadFinishStep() async {
    guard let store = model.settingsStore else { return }
    startAtLogin = await store.get(Settings.autoStartMethod) != .none
    checkForUpdates = await store.get(Settings.checkForUpdates)
  }

  private func saveCheckForUpdates(_ enabled: Bool) async {
    guard let store = model.settingsStore else { return }
    try? await store.set(Settings.checkForUpdates, to: enabled)
    // Applied now rather than at the next launch: the periodic task re-reads the setting
    // on each tick, but starting it here means someone who says yes gets their first
    // check today.
    model.beginUpdateChecks()
  }

  private func saveStartAtLogin(_ enabled: Bool) async {
    guard let store = model.settingsStore else { return }
    // `loginItem` rather than `launchAgent`: it is the one macOS manages itself, shows in
    // System Settings › Login Items where a user can undo it, and needs no privileged
    // install. The agent stays available in settings for anyone who wants it.
    try? await store.set(Settings.autoStartMethod, to: enabled ? .loginItem : AutoStartMethod.none)
  }

  /// The two gates. Everything else advances freely.
  ///
  /// The connection gate exists because an empty password does not mean "open server" — it
  /// FAILS CLOSED, with `serverMisconfigured("No server password is configured")` on every
  /// authenticated request. So finishing setup without one produced a server that looked
  /// installed, showed no error anywhere in the app, and rejected every client with a
  /// message about the Keychain. Requiring it here is the only place that can be fixed
  /// without either weakening auth or nagging on some later screen.
  private var canAdvance: Bool {
    switch step {
    case .permissions:
      return unmetRequired.isEmpty || acknowledgedSkip
    case .connection:
      return passwordRejection == nil
    default:
      return true
    }
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

  private func advance() async {
    // Saved on the way out of the step rather than by a button inside it. A password that
    // was typed and not saved is indistinguishable, on every later screen, from one that
    // was never set.
    if step == .connection, !(await saveConnection()) { return }

    guard step != .done else {
      model.hasCompletedOnboarding = true
      // Recorded, so a later support conversation can establish that the user chose to
      // proceed without a required permission rather than never being asked.
      if !unmetRequired.isEmpty {
        model.recordOnboardingSkip(unmetRequired.map(\.id.rawValue))
      }
      isPresented = false
      return
    }
    step = Step(rawValue: step.rawValue + 1) ?? .done
  }

  /// Writes the password and port. Returns false if the store refused, leaving the step up.
  private func saveConnection() async -> Bool {
    guard let store = model.settingsStore else {
      connectionError = "Settings are not available yet. Try again in a moment."
      return false
    }
    do {
      try await store.set(Settings.password, to: password)
      try await store.set(Settings.socketPort, to: port)
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

/// The connection step: the port a client will use, and the password.
///
/// Has no Save button. Its state belongs to `OnboardingView`, which writes it when Continue
/// is pressed — see `saveConnection`. A step that saved for itself could be walked straight
/// past, and was.
struct ConnectionStep: View {

  @Bindable var model: AppModel
  @Binding var password: String
  @Binding var port: Int
  /// Why the password is unacceptable. Empty string means "nothing typed yet", which is
  /// still unacceptable but should not be shouted at someone who has not started.
  let rejection: String?
  let saveError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Clients authenticate with this password. Choose something long — it is the "
          + "only thing standing between the internet and your messages."
      )
      .foregroundStyle(.secondary)

      LabeledContent("Password") {
        HStack(spacing: 6) {
          SecureField("", text: $password)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
          // Offered rather than imposed. The policy rejects weak passwords, and the fastest
          // way past a rejection is one that passes by construction.
          Button("Generate") { password = PasswordPolicy.generate() }
            .help("Create a strong random password")
        }
      }
      LabeledContent("Port") {
        // A port is an identifier, not a quantity: no thousands separator.
        TextField("", value: $port, format: .number.grouping(.never))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 100)
      }

      // Required, and said so before the Continue button is discovered to be dead. An empty
      // password is not "no authentication" — the server refuses every request with a
      // misconfiguration error, which reads like a bug rather than a missing step.
      if let rejection {
        Label(
          rejection.isEmpty
            ? "A password is required. Without one the server rejects every client."
            : rejection,
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(rejection.isEmpty ? Color.secondary : Color.red)
      } else {
        Label("Strong enough.", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }

      if let saveError {
        Text(saveError).font(.caption).foregroundStyle(.red)
      }
    }
    .task {
      guard let store = model.settingsStore else { return }
      port = await store.get(Settings.socketPort)
      // A password already on the store means this is a re-run of onboarding, not a fresh
      // install. Reading it back would put a real secret in a plain @State for the rest of
      // the session, so the field stays empty and the user re-enters or regenerates one.
    }
  }
}
