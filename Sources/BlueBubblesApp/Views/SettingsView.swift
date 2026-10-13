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
      if model.settings.isAvailable || model.settingsTab == .permissions {
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
      } else if model.settingsTab == .subscription {
        // Beside Permissions rather than below the generated sections: every license
        // setting is hidden, so there is nothing for the registry to draw here.
        SubscriptionSettings(model: model)
      } else {
        // Reached only with settings available: the `Group` in `body` shows the stopped
        // notice otherwise, on every tab but Permissions.
        //
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
            DividedForEach(group.settings) { setting in
              SettingRow(setting: setting, model: model)
            }
          }

          // Directly under Features rather than after every section on the tab, which on
          // General would put Updates between a capability and the settings it belongs
          // with. It draws its own switch (`MessageSearchPanel`), because the switch and
          // the state it turns on are one thing to read: as a row in Features with its
          // status in a section further down, neither half was found.
          if group.section == .features, model.settingsTab == .general {
            MessageSearchSection(model: model)
          }
        }

        // The listener, under the connection settings rather than among them: what it
        // binds to and whether it terminates TLS are the HTTP service's configuration,
        // not two more ways of reaching this server.
        if model.settingsTab == .connection {
          HTTPSettingsSection(model: model)
        }

        // The whole Notifications tab, now that ntfy's four settings have moved into the
        // ntfy integration and the generated part of this tab draws nothing at all.
        if model.settingsTab == .notifications {
          NotificationDeliverySection(model: model)
        }

        // Advanced, because carrying a server's configuration to another Mac is not
        // something anybody does by accident, and the sections it offers name the personal
        // data they would move.
        if model.settingsTab == .advanced {
          ServerArchiveSection(model: model)
        }

        // Certificates, blocks and the allowlist, under the settings that cause them.
        if model.settingsTab == .security {
          SecurityAdministration(model: model)
        }

        // Under the FaceTime toggles that produce the links it clears.
        if model.settingsTab == .privateAPI {
          FaceTimeMaintenance(model: model)
        }

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
///
/// The row owns the lifecycle (reading, following, committing, keeping an unsaved edit) and
/// ONE state value, `SettingRowState`, which decides everything it shows. Each control is
/// its own view (`SettingControls.swift`, and `SecretField` for a secret) handed a binding
/// and a commit.
struct SettingRow: View {

  let setting: AnySetting
  let model: AppModel

  @State private var state: SettingRowState
  /// Briefly shown after a successful write, so a commit is not silent.
  @State private var justSaved = false
  /// The field being edited, by setting key; nil when none is. Focus leaving it is its
  /// commit.
  @FocusState private var editing: String?

  init(setting: AnySetting, model: AppModel) {
    self.setting = setting
    self.model = model
    _state = State(initialValue: SettingRowState(setting: setting))
  }

  // A SECRET IS READ WHEN SOMEBODY ASKS FOR IT, AND NOT BEFORE.
  //
  // `load()` reads every other setting; for a secret it asks `presence` instead, which
  // answers "something is stored" without touching the value. Two reasons, and the second
  // is the one that was actually biting:
  //
  //   1. A read is not free and not silent. On the legacy Keychain — which is every
  //      unsigned development build, and any install whose items predate the entitlement —
  //      `kSecReturnData` raises the system access panel when the item's ACL does not
  //      already trust this binary, and an ad-hoc rebuild invalidates that trust every
  //      time. Opening the Connection tab meant a panel per secure field, before anyone had
  //      asked to see anything.
  //   2. `OnboardingView` already works this way and says why (`Sources/BlueBubblesApp/CLAUDE.md`):
  //      the stored password is never read back into a field, because that puts a real
  //      secret in a plain `@State` String for the life of the view.
  //
  // So the resting state of a secure field is bullets it did not read, and the eye is a
  // LOAD (`revealSecret`), not a mask toggle. `SettingRowState.secretFootnote` says so in
  // words, because a field showing bullets it did not read is indistinguishable from one
  // showing nothing. `state.value` is nil until that read, and that is the whole record of
  // whether it happened.

  // TEXT IS EDITED AS A DRAFT AND COMMITTED ON RETURN OR FOCUS LOSS, not per keystroke.
  //
  // Binding a field straight to a write saves once per character. For `server_address` that
  // announces a half-typed address to Firebase as the server's real address. The password
  // is worse: every prefix is written, the short ones bounce off `PasswordPolicy`, and the
  // first prefix long enough to PASS becomes the live password and disconnects every client,
  // then the next keystroke does it again.
  //
  // Commit-on-blur rather than a debounce, because a debounce still writes prefixes; it only
  // writes fewer of them. And rather than a Save button, because the field is one of thirty
  // on a page and macOS already means "committed" by Enter and by clicking away.
  //
  // And NOT on the way out. Leaving the page with an edit uncommitted keeps the edit
  // (`SettingsModel.keepDraft`) rather than writing it, because a row being torn down is the
  // one place that cannot show what a write refused: a rejected password would sit in a
  // field nobody can see, saved as far as anyone could tell. It comes back with the row,
  // under "Not saved yet", where Return or clicking away commits it and a refusal is shown.

  var body: some View {
    Group {
      if state.isCustom {
        // A bespoke row lays itself out: it may need more than one control, or a second
        // line of its own, so it is given the whole width and supplies its own label. The
        // shared footnotes still apply, and are rendered underneath.
        VStack(alignment: .leading, spacing: 6) {
          SettingCustomControl(setting: setting, selection: state.displayValue) { value in
            commit(.string(value))
          }
          .disabled(state.isLocked)
          ForEach(state.footnotes) { note in note }
        }
        // No vertical padding here: every bespoke row is built from `SettingsRow`, which
        // already carries the row rhythm.
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        // Two columns (label and explanation on the left, control on the right) rather than
        // a control with its help crushed underneath. The help text is often the difference
        // between a setting someone changes confidently and one they leave alone.
        SettingsRow(
          title: setting.presentation.label,
          help: setting.presentation.help,
          footnotes: state.footnotes,
          controlWidth: state.reservesControlColumn ? SettingsMetrics.controlWidth : nil
        ) {
          control
            // A value set on the command line or in the YAML file cannot be usefully changed
            // here: `write` targets the persisted layer, which the override outranks, so the
            // save would appear to succeed and change nothing. The other half is a row whose
            // parent switch is off: see `readRequirements`.
            .disabled(state.isLocked)
            .labelsHidden()
        }
      }
    }
    // Read when the row appears, and again on every write to its own key for a row that
    // follows it (`SettingRowState.followsOwnValue`). Then the edit it was holding when it
    // was last torn down, if there is one.
    .task(id: ownVersion) {
      await load()
      restoreKeptDraft()
    }
    .task(id: requirementsVersion) { await readRequirements() }
    .onDisappear { keepUncommittedDraft() }
    // Focus loss is a commit. Clicking away from a field is how macOS says "done with this
    // one", and it is the case a Save button would exist to catch.
    .onChange(of: editing) { previous, now in
      if previous != nil, now == nil { commitDraft() }
    }
  }

  @ViewBuilder
  private var control: some View {
    switch setting.presentation.control {
    case .toggle:
      SettingToggleControl(isOn: optimistic(default: .bool(false)).switchPosition)

    case .readOnly:
      // Selectable and copyable, but not a field. The affordance is the point: a text field
      // invites typing, and typing here is never what someone means to do.
      CopyableValue(state.value?.stringValue ?? "")

    case .textField, .path:
      SettingTextControl(
        text: $state.draft, focus: $editing, focusKey: setting.key, onSubmit: commitDraft,
        justSaved: justSaved)

    case .secureField:
      // Revealable rather than write-only. A user checking whether the password they
      // configured matches the one in their phone has no other way to find out, and hiding
      // it does not protect against anyone who is already sitting at the unlocked machine.
      SecretField(
        presence: state.secretField,
        text: $state.draft,
        focus: $editing,
        focusKey: setting.key,
        onSubmit: commitDraft,
        reveal: revealSecret,
        forget: forgetSecret,
        generator: setting.presentation.canGenerate
          ? .serverPassword(make: { PasswordPolicy.generate() }, onGenerated: commitDraft)
          : nil
      ) {
        SavedIndicator(isVisible: justSaved)
      }

    case .number(let range):
      SettingNumberControl(
        value: $state.numberDraft, range: range, focus: $editing, focusKey: setting.key,
        onSubmit: commitDraft, onStep: { commit(.int($0)) }, justSaved: justSaved)

    case .picker(let options):
      SettingPickerControl(selection: optimistic(default: .string("")).choice, options: options)

    case .custom:
      EmptyView()
    }
  }

  /// A switch or picker's binding: the value being written shows until the write ends, and
  /// a refused one snaps back beside the error. Text fields never go through this; see the
  /// draft comment above.
  private func optimistic(default fallback: SettingBox) -> Binding<SettingBox> {
    .optimistic(state.value ?? fallback, pending: $state.pending) { newValue in
      await save(newValue)
    }
  }

  /// Moves on every write to this row's own key, for a row that follows it; constant
  /// otherwise. Read only when it can move, because reading it is what subscribes.
  private var ownVersion: UInt64 {
    state.followedKeys.isEmpty ? 0 : model.settings.version(of: state.followedKeys)
  }

  /// Moves on every write to a switch this row hangs off. Constant for the settings that
  /// declare none, which is nearly all of them, so those subscribe to nothing.
  private var requirementsVersion: UInt64 {
    let keys = state.requirementKeys
    return keys.isEmpty ? 0 : model.settings.version(of: keys)
  }

  // MARK: - Reading

  private func load() async {
    do {
      // A secret is read only once somebody has asked. See the comment at the top.
      if setting.isSecret {
        state.secretPresence = try await model.settings.presence(setting)
        // `source` would resolve the value to answer this, which is the read being avoided.
        // Presence knows the same thing: an override is a lookup in two dictionaries, and
        // everything else is the persisted layer or nothing.
        state.source = state.secretPresence.source ?? .declaredDefault
        guard state.value != nil else { return }
      }
      state.value = try await model.settings.read(setting)
      state.source = try await model.settings.source(setting)
      // Not while the field has focus: a reload triggered by something else on the page
      // must not yank half-typed text out from under the person typing it.
      if editing == nil { state.syncDraft() }
    } catch {
      state.error = DiagnosticText.sentence(for: error)
    }
  }

  /// Reads the switches this row hangs off: the whole chain, not just the parent.
  ///
  /// `auto_install_hour` hangs off the automatic install, which hangs off the daily check,
  /// and a row that read one link would draw itself live under a switch that is greyed out.
  /// Which switch to name is `Settings.blockingRequirement`'s decision. Followed rather than
  /// read once (`requirementsVersion`), because the switches are rows on this same page,
  /// usually directly above: reading once meant turning the FaceTime Private API on and
  /// watching the four rows under it stay grey until the tab was left and re-entered.
  private func readRequirements() async {
    let chain = Settings.requirementChain(for: setting)
    guard !chain.isEmpty else { return }
    do {
      var values: [String: Bool] = [:]
      for parent in chain {
        // A parent of some other type answers nil and is treated as on, which cannot
        // happen: `SettingDependencyTests` refuses a non-Bool parent.
        values[parent.key] = try await model.settings.read(parent).boolValue ?? true
      }
      state.blockingRequirement = Settings.blockingRequirement(for: setting) {
        values[$0] ?? true
      }
    } catch {
      state.error = DiagnosticText.sentence(for: error)
    }
  }

  /// Reads the secret out of the Keychain, for the eye. The one place in this view that
  /// materialises a secret, and it runs on a click.
  private func revealSecret() async -> Bool {
    // Already read: nothing to fetch. And a draft the person is part-way through typing is
    // theirs, not the Keychain's: overwriting it with the stored value would discard an edit
    // in order to show what is being replaced, the opposite of what pressing the eye asks.
    guard state.value == nil, !state.hasUnsavedEdit else { return true }
    do {
      let stored = try await model.settings.read(setting)
      state.secretPresence = try await model.settings.presence(setting)

      // THE READ FAILING IS NOT THE READ RETURNING NOTHING, and `isUnreadable` is the only
      // thing that can tell them apart here. `read` resolves an unreadable secret to the
      // declared default, because `resolve` has nowhere to put "unknown", so it hands back
      // `""`, exactly like a secret genuinely set to the empty string. Inferring
      // "unreadable" from emptiness would report a Keychain fault for an empty password, and
      // the reasonable response to a blank password field is Generate, the one irreversible
      // thing on this page.
      if try await model.settings.isUnreadable(setting.key) {
        // Said by the secret's own footnote, in the same words the service form uses.
        state.secretPresence = .unreadable
        return false
      }
      state.value = stored
      state.draft = stored.stringValue ?? ""
      return true
    } catch {
      state.error = DiagnosticText.sentence(for: error)
      return false
    }
  }

  /// Forgets a revealed secret again: the value goes back out of the row, so the next reveal
  /// is a fresh read and the plaintext is not sitting in view state for the rest of the
  /// session. Kept when there is an uncommitted edit, which is the person's own text.
  private func forgetSecret() {
    guard setting.isSecret, state.value != nil, !state.hasUnsavedEdit else { return }
    state.value = nil
    state.draft = ""
  }

  // MARK: - Writing

  /// Writes the draft, if it actually differs from what is stored.
  private func commitDraft() {
    guard let newValue = state.draftToCommit else { return }
    commit(newValue)
  }

  private func commit(_ newValue: SettingBox) {
    Task { await save(newValue) }
  }

  /// Writes, and shows the validator's own reason on rejection.
  ///
  /// Nothing is applied to the row before the write lands: a rejected password would
  /// otherwise leave the field showing something the server never accepted, which reads as
  /// "it saved" right next to an error saying it did not.
  private func save(_ newValue: SettingBox) async {
    do {
      try await model.settings.write(setting, newValue)
      state.error = nil
      // A secret the person just wrote is one they already know, and the field holds it.
      // Without this the reload below would return the row to its unread state, blank the
      // field they are looking at, and go on showing "Not saved yet" for a write that landed.
      if setting.isSecret { state.value = newValue }
      model.settings.discardDraft(for: setting.key)
      await load()
      flashSaved()
    } catch {
      // The validator's own sentence, not a generic failure. "Too short; use at least 8
      // characters" is actionable; "could not save" is not, and neither is a raw enum
      // description.
      state.error = DiagnosticText.sentence(for: error)
      // Back to what the store holds, beside the error saying why.
      await load()
    }
  }

  private func flashSaved() {
    justSaved = true
    Task {
      try? await Task.sleep(for: .seconds(1.6))
      justSaved = false
    }
  }

  // MARK: - Leaving mid-edit

  private func keepUncommittedDraft() {
    guard let text = state.uncommittedText else { return }
    model.settings.keepDraft(text, typedOver: state.draftBase, for: setting.key)
  }

  private func restoreKeptDraft() {
    guard let kept = model.settings.takeDraft(for: setting.key, ifStillOver: state.draftBase)
    else { return }
    state.restoreDraft(kept)
  }
}
