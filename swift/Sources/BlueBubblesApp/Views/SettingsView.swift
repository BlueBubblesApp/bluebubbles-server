//  SettingsView
//  The settings screen, generated from the registry.
//
//  ONE row view plus a handful of bespoke ones, driven by the `SettingPresentation` each
//  setting already declares. The Electron UI had ~35 near-identical `*Field.tsx` components —
//  a file per setting, each re-implementing the same load/validate/save/toast cycle — and the
//  failure mode was that adding a setting meant remembering to add a component, so settings
//  existed that no screen showed.
//
//  Here, declaring a setting with a presentation IS adding it to this screen.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBPrivateAPI
import BBSettings
import SwiftUI

struct SettingsView: View {

  @Bindable var model: AppModel

  var body: some View {
    @Bindable var model = model
    return Group {
      if model.settingsStore != nil || model.settingsTab == .permissions {
        page
      } else {
        ContentUnavailableView(
          "Server not running",
          systemImage: "gearshape",
          description: Text("Start the server to view and change settings.")
        )
      }
    }
    // Over the content, not beside it — the page scrolls underneath the bar.
    .overlay(alignment: .bottom) {
      FloatingBar(
        selection: $model.settingsTab,
        items: SettingsTab.allCases.map { tab in
          FloatingBarItem(
            value: tab,
            title: tab.title,
            symbol: tab.symbol,
            // Permissions live in settings rather than the sidebar, and this badge is the
            // one signal telling someone to look.
            badge: tab == .permissions ? model.permissions.unsatisfiedRequiredCount : 0
          )
        }
      )
    }
  }

  @ViewBuilder
  private var page: some View {
    SettingsPage(bottomInset: FloatingBar<SettingsTab>.reservedHeight) {
      if model.settingsTab == .permissions {
        PermissionsSettings(model: model)
      } else if let store = model.settingsStore {
        // Said once at the top rather than repeated per toggle. NOTHING on this page works
        // without SIP disabled — every switch here injects a dylib — and a user who has not
        // done that will otherwise turn one on, see it fail, and have no idea the two are
        // connected.
        if model.settingsTab == .privateAPI {
          PrivateAPIPrerequisiteNote()
          PrivateAPIStatusCard(model: model)
        }

        // Driven off the TAB's section list rather than the registry's order, so the
        // grouping is the one `SettingsTab` states and a section it does not name
        // still appears — under Advanced — instead of disappearing.
        ForEach(sections(for: model.settingsTab), id: \.section) { group in
          SettingsSection(group.section, subtitle: Self.description(for: group.section)) {
            ForEach(Array(group.settings.enumerated()), id: \.element.id) { index, setting in
              if index > 0 { SettingsDivider() }
              SettingRow(setting: setting, store: store)
            }
          }
        }

        // Certificates, blocks and the allowlist, under the settings that cause them.
        if model.settingsTab == .security {
          SecurityAdministration(model: model)
        }

        // Under the FaceTime toggles that produce the links it clears.
        if model.settingsTab == .privateAPI {
          FaceTimeMaintenance(model: model)
        }

        // Under Features, because that is where the capability it turns on is described.
        if model.settingsTab == .general {
          GroupChatShortcutSection(model: model)
          SetupSection(model: model)
        }
      }
    }
  }

  /// The registry sections belonging to a tab, in the tab's declared order.
  private func sections(for tab: SettingsTab) -> [(section: String, settings: [AnySetting])] {
    Settings.renderableSections
      .filter { SettingsTab.containing(section: $0.section) == tab }
      .sorted { first, second in
        let order = tab.sections
        let firstIndex = order.firstIndex(of: first.section) ?? order.count
        let secondIndex = order.firstIndex(of: second.section) ?? order.count
        return firstIndex < secondIndex
      }
  }
}

extension SettingsView {
  /// A sentence per section, so a header says what the group is FOR.
  ///
  /// Written here rather than on each setting because it describes the group, and repeating
  /// it on every member would be noise. An unknown section gets none rather than a
  /// placeholder — a section with no explanation is better than one with an empty promise.
  static func description(for section: String) -> String? {
    switch section {
    case "Connection": "How clients reach this server, and what it listens on."
    case "Security": "Passwords, encryption, and who is allowed to connect."
    // Both sections now sit on the Private API tab, so each subtitle names the APP it
    // configures rather than repeating the mechanism the page header already explains.
    case "Messages": "Reactions, editing, unsending, typing indicators and group management."
    case "FaceTime": "Answering, generating links, and handing calls to a client."
    case "Find My": "Reading locations, and sharing this Mac's location out."
    case "Notifications": "Delivery to clients that are not currently connected."
    case "Features": "Optional behaviour."
    case "Updates": "How this server updates itself."
    case "Advanced": "Settings most installs never need to change."
    case "Debug": "Diagnostics and logging."
    default: nil
    }
  }
}

/// One setting, rendered from its declared presentation.
struct SettingRow: View {

  let setting: AnySetting
  let store: SettingsStore

  @State private var value: SettingBox?
  @State private var source: SettingSource = .declaredDefault
  @State private var error: String?
  @State private var isRevealed = false

  // TEXT IS EDITED AS A DRAFT AND COMMITTED ON ENTER OR FOCUS LOSS, not per keystroke.
  //
  // Binding a field straight to `save` writes once per character, and the damage is not
  // theoretical. `server_address` was announced to Firebase once per keystroke, so a
  // half-typed address went out as the server's real address — a user who fat-fingered the
  // field left it holding a single letter. The password is worse: every prefix is written,
  // the short ones bounce off `PasswordPolicy`, and the first prefix long enough to PASS
  // becomes the live password and disconnects every client — then the next keystroke does
  // it again.
  //
  // Commit-on-blur rather than a debounce, because a debounce still writes prefixes; it
  // only writes fewer of them. And rather than a Save button, because the field is one of
  // thirty on a page and macOS already means "committed" by Enter and by clicking away.
  @State private var draft: String = ""
  @State private var numberDraft: Int = 0
  @FocusState private var isEditing: Bool
  /// Briefly shown after a successful write, so a commit is not silent.
  @State private var justSaved = false

  var body: some View {
    Group {
      if isCustom {
        // A bespoke row lays itself out — it may need more than one control, or a
        // second line of its own — so it is given the whole width and supplies its own
        // label. The shared footnotes still apply, and are rendered underneath.
        VStack(alignment: .leading, spacing: 6) {
          custom
            .disabled(source > .persistedStore)
          ForEach(Array(footnotes.enumerated()), id: \.offset) { _, note in
            note
          }
        }
        // No vertical padding here: every bespoke row is built from `SettingsRow`,
        // which already carries the row rhythm.
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        // Two columns — label and explanation on the left, control on the right —
        // rather than a control with its help crushed underneath. The help text is
        // often the difference between a setting someone changes confidently and one
        // they leave alone.
        SettingsRow(
          title: setting.presentation.label,
          help: setting.presentation.help,
          footnotes: footnotes
        ) {
          control
            // A value set on the command line or in the YAML file cannot be
            // usefully changed here — `write` targets the persisted layer, which
            // the override outranks, so the save would appear to succeed and
            // change nothing.
            .disabled(source > .persistedStore)
            .labelsHidden()
        }
      }
    }
    .task { await load() }
    // Navigating away commits too. Without it, switching tabs mid-edit drops the change on
    // the floor — the one outcome worse than saving too eagerly.
    .onDisappear { commitDraft() }
    // Focus loss is a commit. Clicking away from a field is how macOS says "done with
    // this one", and it is the case a Save button would exist to catch.
    .onChange(of: isEditing) { wasEditing, nowEditing in
      if wasEditing, !nowEditing { commitDraft() }
    }
  }

  private var isCustom: Bool {
    if case .custom = setting.presentation.control { return true }
    return false
  }

  /// The lines that appear under a row when there is something to say.
  /// Whether the field holds something not yet written.
  ///
  /// Needed because focus loss is NOT dependable on macOS: clicking empty space does not
  /// resign first responder, so a field can sit holding an uncommitted value indefinitely
  /// while looking exactly like a saved one. Rather than guess with a timer — which for the
  /// password would write whatever prefix existed when the user paused — the pending state
  /// is shown and the way to resolve it is named.
  private var hasUnsavedEdit: Bool {
    guard source <= .persistedStore else { return false }
    switch setting.presentation.control {
    case .number: return numberDraft != (value?.intValue ?? 0)
    case .textField, .path, .secureField: return draft != (value?.stringValue ?? "")
    default: return false
    }
  }

  private var footnotes: [SettingsFootnote] {
    var notes: [SettingsFootnote] = []
    if hasUnsavedEdit {
      notes.append(
        SettingsFootnote(
          text: "Not saved yet — press Return, or click another field.",
          // Neutral, not warning. This appears on the first keystroke of a perfectly normal
          // edit; colouring it as a problem would make ordinary typing look like a fault.
          symbol: "pencil.circle", tone: .neutral
        ))
    }
    if source > .persistedStore {
      notes.append(
        SettingsFootnote(
          text: source == .commandLine
            ? "Set on the command line; not editable here."
            : "Set in the configuration file; not editable here.",
          symbol: "lock"
        ))
    }
    if let error {
      notes.append(SettingsFootnote(text: error, symbol: "xmark.circle", tone: .error))
    }
    // Advisory, never a gate. A password migrated from the Electron server is deliberately
    // accepted however weak it is — rejecting it at upgrade time would lock the install
    // out of its own clients — so the only thing left is to say so where it can be fixed.
    if let advice = passwordAdvice {
      notes.append(
        SettingsFootnote(
          text: advice, symbol: "exclamationmark.triangle", tone: .warning
        ))
    }
    return notes
  }

  @ViewBuilder
  private var control: some View {
    switch setting.presentation.control {
    case .toggle:
      Toggle(
        "",
        isOn: Binding(
          get: { value?.boolValue ?? false },
          set: { save(.bool($0)) }
        )
      )
      .toggleStyle(.switch)

    case .readOnly:
      // Selectable and copyable, but not a field. The affordance is the point: a text field
      // invites typing, and typing here is never what someone means to do.
      let published = value?.stringValue ?? ""
      HStack(spacing: 6) {
        Text(published.isEmpty ? "Not set" : published)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(published.isEmpty ? Color.secondary : Color.primary)
          .textSelection(.enabled)
        if !published.isEmpty {
          let current = published
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(current, forType: .string)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy")
        }
      }

    case .textField, .path:
      HStack(spacing: 6) {
        TextField("", text: $draft)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .focused($isEditing)
          .onSubmit { commitDraft() }
        savedIndicator
      }

    case .secureField:
      HStack(spacing: 6) {
        // Revealable rather than write-only. A user checking whether the password they
        // configured matches the one in their phone has no other way to find out, and
        // hiding it does not protect against anyone who is already sitting at the
        // unlocked machine.
        SwiftUI.Group {
          if isRevealed {
            TextField("", text: secureBinding)
          } else {
            SecureField("", text: secureBinding)
          }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        // The same commit wiring every other field gets. Rebinding this to the draft
        // WITHOUT it left the password unable to save at all — worse than the per-keystroke
        // writes it replaced, and silent about it.
        .focused($isEditing)
        .onSubmit { commitDraft() }

        Button {
          isRevealed.toggle()
        } label: {
          Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isRevealed ? "Hide" : "Reveal")

        if setting.presentation.canGenerate {
          Button("Generate") {
            draft = PasswordPolicy.generate()
            // REVEALED, because a secret you cannot read is one you cannot put into a
            // client. Generating while masked produces a password the user now has to
            // reset in order to find out what it is.
            isRevealed = true
            // Committed immediately: a click is a finished decision, where a keystroke is
            // one letter of one. It also means the checkmark confirms the new password is
            // live before the user copies it.
            commitDraft()
          }
          .help("Replace this with a strong random password")
        }

        savedIndicator
      }

    case .number(let range):
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        TextField("", value: $numberDraft, format: .number)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .frame(width: 120)
          .focused($isEditing)
          .onSubmit { commitDraft() }
        // A stepper alongside the field, bounded when the setting declares a range. The
        // stepper commits immediately: a click is a finished decision, where a keystroke
        // is a letter of one.
        if let range {
          Stepper(
            "",
            value: Binding(
              get: { numberDraft },
              set: {
                numberDraft = $0
                save(.int($0))
              }
            ),
            in: range
          )
          .labelsHidden()
        }
        savedIndicator
      }

    case .picker(let options):
      Picker(
        "",
        selection: Binding(
          get: { value?.stringValue ?? "" },
          set: { save(.string($0)) }
        )
      ) {
        ForEach(options, id: \.value) { option in
          Text(option.label).tag(option.value)
        }
      }
      .labelsHidden()
      .controlSize(.large)
      .frame(maxWidth: 240)

    case .custom:
      EmptyView()
    }
  }

  /// A control whose options depend on THIS machine, so it cannot be generated from a static
  /// declaration. The two network ones are here; anything else without a bespoke view falls
  /// through to read-only, so a setting that lost its view is visible rather than silently
  /// gone.
  @ViewBuilder
  private var custom: some View {
    switch setting.key {
    case Settings.connectionMethod.key:
      // Options are the INSTALLED services in the exclusive `reverse-proxy` category,
      // not enum cases — which is what lets a third-party tunnel appear here without
      // this file changing.
      ConnectionMethodRow(
        setting: setting,
        selection: displayValue,
        onChange: { value in save(.string(value)) }
      )
    case Settings.ntfyEvents.key:
      // The same picker the webhook editor uses. Both sinks filter on the same event
      // vocabulary, and two pickers would eventually offer two different ones.
      SettingsWideRow(
        title: setting.presentation.label,
        help: setting.presentation.help
      ) {
        EventSubscriptionPicker(
          subscription: Binding(
            get: { EventSubscription(settingValue: value?.stringValue ?? "*") },
            set: { save(.string($0.settingValue)) }
          ),
          emptyWarning: "Pick at least one event, or switch back to All events. "
            + "Nothing is published to the topic while this is empty."
        )
      }
    case Settings.bindAddress.key:
      NetworkAddressPicker(
        label: setting.presentation.label,
        help: setting.presentation.help,
        selection: displayValue,
        choices: NetworkAddressChoices.bind(),
        onChange: { value in save(.string(value)) }
      )
    default:
      SettingsRow(title: setting.presentation.label, help: setting.presentation.help) {
        Text(displayValue).foregroundStyle(.secondary)
      }
    }
  }

  /// The password field edits the same draft as any other text field.
  ///
  /// It is the setting that most needed this: writing per keystroke meant every prefix of a
  /// new password was tried, and the first acceptable one took effect — logging out every
  /// client mid-typing.
  private var secureBinding: Binding<String> { $draft }

  private var displayValue: String {
    guard let value else { return "—" }
    // A secret is never rendered, even in the read-only fallback.
    if setting.isSecret { return "••••••••" }
    switch value {
    case .bool(let flag): return flag ? "On" : "Off"
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .string(let text): return text
    }
  }

  /// The strength note for the server password, and only for it.
  ///
  /// Keyed on the setting's own key rather than on `.secureField`, because the ngrok and
  /// zrok tokens are secure fields too and are not passwords anyone chose — scoring them
  /// would be noise attached to a value the user cannot make stronger.
  private var passwordAdvice: String? {
    guard setting.key == Settings.password.key else { return nil }
    return PasswordPolicy().assess(value?.stringValue ?? "").advice
  }

  private func load() async {
    value = await setting.read(store)
    source = await setting.source(store)
    syncDraft()
  }

  /// Writes, and shows the validator's own reason on rejection.
  ///
  /// The value is NOT optimistically applied to the local state before the write: a
  /// rejected password would otherwise leave the field showing something the server never
  /// accepted, which reads as "it saved" right next to an error saying it did not.
  /// Mirrors the stored value into the draft.
  ///
  /// Skipped while the field has focus, so a reload triggered by something else on the page
  /// does not yank half-typed text out from under the person typing it.
  private func syncDraft() {
    guard !isEditing else { return }
    draft = value?.stringValue ?? ""
    numberDraft = value?.intValue ?? 0
  }

  /// Writes the draft, if it actually differs from what is stored.
  ///
  /// The equality check is what makes commit-on-blur quiet: tabbing through a page of
  /// settings must not rewrite every one of them, and a no-op write of the password would
  /// still disconnect clients.
  private func commitDraft() {
    switch setting.presentation.control {
    case .number:
      guard numberDraft != value?.intValue else { return }
      save(.int(numberDraft))
    case .textField, .path, .secureField:
      guard draft != (value?.stringValue ?? "") else { return }
      save(.string(draft))
    default:
      return
    }
  }

  /// A checkmark for a moment after a write lands.
  ///
  /// Commit-on-blur has one weakness a per-keystroke write does not: the moment of saving
  /// is invisible, so "did that stick?" has no answer. This is that answer.
  @ViewBuilder
  private var savedIndicator: some View {
    Image(systemName: "checkmark.circle.fill")
      .foregroundStyle(.green)
      .opacity(justSaved ? 1 : 0)
      .animation(.easeInOut(duration: 0.2), value: justSaved)
      .accessibilityHidden(!justSaved)
      .accessibilityLabel("Saved")
  }

  private func save(_ newValue: SettingBox) {
    Task {
      do {
        try await setting.write(store, newValue)
        error = nil
        justSaved = true
        await load()
        try? await Task.sleep(for: .seconds(1.6))
        justSaved = false
      } catch {
        // The validator's own sentence, not a generic failure. "Too short — use at least 8
        // characters" is actionable; "could not save" is not, and neither is a raw enum
        // description. Falling back to one for anything that is not a `SettingsError` would
        // cover every password rejection, since the policy throws its own type.
        self.error = userFacingMessage(error)
        await load()
      }
    }
  }
}

/// The one prerequisite every Private API feature shares.
///
/// Placed above the sections rather than as help text on the first toggle, because it is not
/// advice about a setting — it is the reason none of them will do anything. The Permissions
/// page reports the live SIP state; this says what to do about it.
struct PrivateAPIPrerequisiteNote: View {

  var body: some View {
    GlassCard {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: "exclamationmark.shield")
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 4) {
          Text("These features need System Integrity Protection disabled.")
            .font(.headline)
          Text(
            "Everything on this page works by injecting a helper into Apple's apps, which "
              + "macOS blocks while SIP is on. The rest of the server — sending, receiving, "
              + "attachments — works normally without it."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          Link(
            "Read the setup guide",
            destination: URL(string: "https://docs.bluebubbles.app/private-api/installation")!
          )
          .font(.callout)
        }
        Spacer(minLength: 0)
      }
    }
  }
}

/// Whether the Private API is actually working, as opposed to switched on.
///
/// Those were the same claim on screen, and they are not the same thing. Injection quits and
/// relaunches somebody else's app and waits for a helper inside it to call back; any of that
/// can fail, or simply never finish, while every toggle on the page still reads "on". The
/// server now bounds that wait and carries on without it — which is the right behaviour and
/// completely invisible unless something says so here.
struct PrivateAPIStatusCard: View {

  let model: AppModel

  @State private var outcome: PrivateAPIRuntime.StartOutcome?
  @State private var isConnected = false

  var body: some View {
    GlassCard {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: symbol)
          .foregroundStyle(tint)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
    }
    .task {
      // Polled rather than observed: the runtime is an actor behind the server, and the
      // states worth showing change on the order of seconds during startup.
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func refresh() async {
    guard let runtime = await model.privateAPIAccess?.privateAPIRuntime else {
      outcome = nil
      isConnected = false
      return
    }
    outcome = await runtime.startOutcome
    isConnected = await runtime.isConnected
  }

  private var title: String {
    switch outcome {
    case .none, .notStarted: "Private API is not running"
    case .disabled: "Private API is switched off"
    case .running:
      isConnected ? "Private API is connected" : "Private API is waiting for the helper"
    case .timedOut: "Private API did not finish starting"
    case .failed: "Private API failed to start"
    }
  }

  private var detail: String {
    switch outcome {
    case .none, .notStarted:
      "The server is not running, so nothing has been injected yet."
    case .disabled:
      "Turn on a switch below to inject the helper into that app."
    case .running:
      isConnected
        ? "The helper is injected and answering. Reactions, editing, unsending and typing "
          + "indicators are available."
        : "The helper was injected but has not called back yet. This is normal for a few "
          + "seconds after startup."
    case .timedOut:
      // Names the remedy, because the usual cause is the other app rather than this one.
      "Injection did not complete in time, so the server started without it. Everything "
        + "else works normally. Quitting and reopening Messages usually clears this."
    case .failed(let reason):
      reason
    }
  }

  private var symbol: String {
    switch outcome {
    case .running: isConnected ? "checkmark.circle.fill" : "clock"
    case .timedOut, .failed: "exclamationmark.triangle.fill"
    case .none, .disabled, .notStarted: "circle.dashed"
    }
  }

  private var tint: Color {
    switch outcome {
    case .running: isConnected ? .green : .secondary
    case .timedOut: .orange
    case .failed: .red
    case .none, .disabled, .notStarted: .secondary
    }
  }
}
