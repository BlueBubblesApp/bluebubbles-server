//  SettingsView
//  The settings screen, generated from the registry.
//
//  ONE row view plus a handful of bespoke ones, driven by the `SettingPresentation` each
//  setting already declares. A component per setting means adding a setting is also
//  remembering to add a component, and settings end up that no screen shows.
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

  /// What state the Private API is in, decided by `FeatureAvailabilityView` and read here so
  /// the rest of the page follows it; see `PrivateAPIPresence` for why three states and not
  /// two.
  ///
  /// Starts connected so a page that has not polled yet does not open by telling somebody
  /// with a working setup to go and disable SIP.
  @State private var privateAPIPresence: PrivateAPIPresence = .connected

  var body: some View {
    Group {
      if model.settingsStore != nil || model.settingsTab == .permissions {
        page
      } else {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "gearshape"),
          purpose: "view and change settings")
      }
    }
    // Over the content, not beside it: the page scrolls underneath the bar.
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
        },
        // NOT collapsed on a timer, unlike the log-level filter this control is shared
        // with. There the bar is a secondary choice over content that scrolls beneath it;
        // here it IS the navigation, across seven tabs. Someone who arrives on General and
        // reads for five seconds was left with a pill saying "General" and had to hover it
        // to learn that Security exists.
        minimizeAfter: nil
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
        // without SIP disabled: every switch here injects a dylib, and a user who has not
        // done that will otherwise turn one on, see it fail, and have no idea the two are
        // connected.
        // The features card is FIRST: "what does this get me" is the question somebody
        // arrives with, and it is the one that makes the rest of the page worth reading.
        if model.settingsTab == .privateAPI {
          FeatureAvailabilityView(model: model, presence: $privateAPIPresence)
          // The SIP note is a prerequisite for SETTING THIS UP, so it is noise once the
          // helper is answering: it can only tell somebody who has already done it that
          // they need to do it.
          if privateAPIPresence.showsPrerequisiteNote {
            PrivateAPIPrerequisiteNote()
          }
          // And the connection status is only worth showing once there is a connection to
          // have an opinion about. Switched off, it would explain at length that nothing
          // has been injected, on a page already saying what injecting it would get you.
          if privateAPIPresence.showsStatusCard {
            PrivateAPIStatusCard(model: model)
          }
        }

        // Driven off the TAB's section list rather than the registry's order, so the
        // grouping is the one `SettingsTab` states and a section it does not name
        // still appears (under Advanced) instead of disappearing.
        ForEach(sections(for: model.settingsTab), id: \.section) { group in
          SettingsSection(group.section.title, subtitle: group.section.summary) {
            ForEach(Array(group.settings.enumerated()), id: \.element.id) { index, setting in
              if index > 0 { SettingsDivider() }
              SettingRow(setting: setting, store: store)
            }
          }
        }

        // The listener, under the connection settings rather than among them: what it
        // binds to and whether it terminates TLS are the HTTP service's configuration,
        // not two more ways of reaching this server.
        if model.settingsTab == .connection {
          HTTPSettingsSection(model: model)
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
  private func sections(
    for tab: SettingsTab
  ) -> [(section: SettingSection, settings: [AnySetting])] {
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

/// One setting, rendered from its declared presentation.
struct SettingRow: View {

  let setting: AnySetting
  let store: SettingsStore

  @State private var value: SettingBox?
  @State private var source: SettingSource = .declaredDefault
  @State private var error: String?
  @State private var isRevealed = false

  // A SWITCH OR A PICKER SHOWS ITS NEW VALUE WHILE THE WRITE IS IN FLIGHT.
  //
  // Bound straight to `value`, a toggle animates to its new position, SwiftUI re-reads the
  // getter on the next render and finds the stored value unchanged, the switch flips back,
  // and it flips forward again when `load()` returns. On a write that restarts a service
  // that is a visible round trip, and it reads as a switch that refused to move.
  //
  // So the value being written is held here from `save` until the reload lands, and the
  // toggle and picker read it first. It is cleared on success AND on failure: a rejected
  // write must snap the control back to what the store actually holds, next to the error
  // that says why, which is the reason text fields are NOT optimistic (see `save`).
  @State private var pending: SettingBox?

  // TEXT IS EDITED AS A DRAFT AND COMMITTED ON ENTER OR FOCUS LOSS, not per keystroke.
  //
  // Binding a field straight to `save` writes once per character. For `server_address`
  // that announces a half-typed address to Firebase as the server's real address. The
  // password is worse: every prefix is written, the short ones bounce off `PasswordPolicy`,
  // and the first prefix long enough to PASS becomes the live password and disconnects
  // every client, then the next keystroke does it again.
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
        // A bespoke row lays itself out: it may need more than one control, or a
        // second line of its own, so it is given the whole width and supplies its own
        // label. The shared footnotes still apply, and are rendered underneath.
        VStack(alignment: .leading, spacing: 6) {
          custom
            .disabled(source > .persistedStore)
          ForEach(footnotes) { note in note }
        }
        // No vertical padding here: every bespoke row is built from `SettingsRow`,
        // which already carries the row rhythm.
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        // Two columns (label and explanation on the left, control on the right)
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
            // usefully changed here: `write` targets the persisted layer, which
            // the override outranks, so the save would appear to succeed and
            // change nothing.
            .disabled(source > .persistedStore)
            .labelsHidden()
        }
      }
    }
    .task { await load() }
    // Navigating away commits too. Without it, switching tabs mid-edit drops the change on
    // the floor: the one outcome worse than saving too eagerly.
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
  /// while looking exactly like a saved one. Rather than guess with a timer (which for the
  /// password would write whatever prefix existed when the user paused) the pending state
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
          text: "Not saved yet; press Return, or click another field.",
          kind: .unsaved,
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
          kind: .locked,
          symbol: "lock"
        ))
    }
    if let error {
      notes.append(
        SettingsFootnote(text: error, kind: .error, symbol: "xmark.circle", tone: .error))
    }
    // Advisory, never a gate. A password migrated from the Electron server is deliberately
    // accepted however weak it is (rejecting it at upgrade time would lock the install
    // out of its own clients) so the only thing left is to say so where it can be fixed.
    if let advice = passwordAdvice {
      notes.append(
        SettingsFootnote(
          text: advice, kind: .advice, symbol: "exclamationmark.triangle", tone: .warning
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
          get: { (pending ?? value)?.boolValue ?? false },
          set: { save(.bool($0)) }
        )
      )
      .toggleStyle(.switch)

    case .readOnly:
      // Selectable and copyable, but not a field. The affordance is the point: a text field
      // invites typing, and typing here is never what someone means to do.
      CopyableValue(value?.stringValue ?? "")

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
      // Generate sits ABOVE the field rather than beside it. A settings row's control
      // column is 320 points, and a text field, a reveal button, a word-width button and
      // the saved tick do not share that without the field itself becoming unusable, for
      // the one value in the app most likely to be read character by character.
      //
      // Still the word, not an icon: `PasswordPolicy.Rejection.tooPredictable` tells the
      // reader to "use Generate", and that sentence is shown on this very row when a
      // password is refused. An icon would leave the advice naming a control that is not
      // there, which is the failure the registry's own comment warns about.
      VStack(alignment: .trailing, spacing: 6) {
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
          .controlSize(.small)
        }

        HStack(spacing: 6) {
          // Revealable rather than write-only. A user checking whether the password they
          // configured matches the one in their phone has no other way to find out, and
          // hiding it does not protect against anyone who is already sitting at the
          // unlocked machine.
          SwiftUI.Group {
            if isRevealed {
              TextField("", text: $draft)
            } else {
              SecureField("", text: $draft)
            }
          }
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          // The same commit wiring every other field gets. A draft binding without it
          // leaves the password unable to save at all, silently.
          .focused($isEditing)
          .onSubmit { commitDraft() }

          Button {
            isRevealed.toggle()
          } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(isRevealed ? "Hide" : "Reveal")

          savedIndicator
        }
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
          get: { (pending ?? value)?.stringValue ?? "" },
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
    // Exhaustive over `CustomSettingControl`, so a control added there does not compile
    // until it is drawn here. The `nil` arm is for a setting declared `.custom` with no
    // control written yet: it renders read-only rather than blank, and
    // `CustomSettingControlTests` fails so it does not stay that way.
    switch CustomSettingControl(key: setting.key) {
    case .connectionMethod:
      ConnectionMethodRow(
        setting: setting,
        selection: displayValue,
        onChange: { value in save(.string(value)) }
      )
    case .ntfyEvents:
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
    case .bindAddress:
      NetworkAddressPicker(
        label: setting.presentation.label,
        help: setting.presentation.help,
        selection: displayValue,
        choices: NetworkAddressChoices.bind(),
        onChange: { value in save(.string(value)) }
      )
    case nil:
      SettingsRow(title: setting.presentation.label, help: setting.presentation.help) {
        Text(displayValue).foregroundStyle(.secondary)
      }
    }
  }

  private var displayValue: String {
    guard let value else { return "-" }
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
  /// zrok tokens are secure fields too and are not passwords anyone chose: scoring them
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
    // Shown by the toggle and the picker until the reload below replaces it. A text field
    // is not read through this: its draft is what it shows, so holding it is harmless.
    pending = newValue
    Task {
      do {
        try await setting.write(store, newValue)
        error = nil
        justSaved = true
        await load()
        pending = nil
        try? await Task.sleep(for: .seconds(1.6))
        justSaved = false
      } catch {
        // The validator's own sentence, not a generic failure. "Too short; use at least 8
        // characters" is actionable; "could not save" is not, and neither is a raw enum
        // description. Falling back to one for anything that is not a `SettingsError` would
        // cover every password rejection, since the policy throws its own type.
        self.error = DiagnosticText.sentence(for: error)
        await load()
        // Back to what the store holds, beside the error saying why.
        pending = nil
      }
    }
  }
}
