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
  /// Whether the "replace the password?" dialog is up. See the Generate button.
  @State private var isConfirmingGenerate = false

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
  //      secret in a plain `@State` String for the life of the view. The settings screen
  //      was the one place still doing it.
  //
  // So the resting state of a secure field is bullets it did not read, and the eye is a
  // LOAD, not a mask toggle. `secretFootnote` says so in words, because a field showing
  // bullets it did not read is indistinguishable from one showing nothing.
  /// What is known about the secret without reading it. `.absent` on every other row.
  @State private var secretPresence: SecretPresence = .absent
  /// Whether the Keychain read has happened, so `draft` holds the real value.
  @State private var secretIsLoaded = false
  /// While the Keychain is being asked, which on the legacy store can be a modal panel.
  @State private var isRevealing = false

  // THE SWITCHES THIS ROW DOES NOTHING WITHOUT, when it declares one.
  //
  // The whole chain, not just the parent: `auto_install_hour` hangs off the automatic
  // install, which hangs off the daily check, and a row that read one link would draw
  // itself live under a switch that is greyed out. `Settings.requirementChain` walks it and
  // `Settings.blockingRequirement` picks the one to name.
  //
  // Empty while nothing has been read, which reads as SATISFIED: a row that flashed disabled
  // on every appearance would be worse than one that is briefly live.
  //
  // Followed rather than read once, because the switches are rows on this same page, usually
  // directly above: reading once meant turning the FaceTime Private API on and watching the
  // four rows under it stay grey until the tab was left and re-entered. Only a row that
  // DECLARES a dependency subscribes, so this is a handful of streams across the whole app.
  // `OnboardingView.mirrorPrivateAPIState` follows the store the same way and for the same
  // reason.
  @State private var requirementValues: [String: Bool] = [:]

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
            .disabled(isLocked)
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
            // change nothing. The other half is a row whose parent switch is off:
            // see `dependencyIsSatisfied`.
            .disabled(isLocked)
            .labelsHidden()
        }
      }
    }
    .task { await load() }
    .task { await followDependency() }
    .task { await followOwnValue() }
    // Navigating away commits too. Without it, switching tabs mid-edit drops the change on
    // the floor: the one outcome worse than saving too eagerly.
    .onDisappear { commitDraft() }
    // Focus loss is a commit. Clicking away from a field is how macOS says "done with
    // this one", and it is the case a Save button would exist to catch.
    .onChange(of: isEditing) { wasEditing, nowEditing in
      if wasEditing, !nowEditing { commitDraft() }
    }
  }

  /// Everything this row decides about itself: locked, unsaved, what it prints, and the
  /// notes under it. `SettingRowState`, not `private var`s here — see that file.
  private var state: SettingRowState {
    SettingRowState(
      setting: setting,
      value: value,
      source: source,
      draft: draft,
      numberDraft: numberDraft,
      blockingRequirement: Settings.blockingRequirement(for: setting) {
        requirementValues[$0] ?? true
      },
      error: error,
      secretPresence: secretPresence
    )
  }

  private var isCustom: Bool { state.isCustom }
  private var blockingRequirement: AnySetting? { state.blockingRequirement }
  private var isLocked: Bool { state.isLocked }

  /// Re-reads this row's OWN value while it is on screen, for the rows that need it.
  ///
  /// `SettingRowState.followsOwnValue` is the rule and carries the why; it is on that type
  /// rather than here because it is a decision, and this file's siblings do not hold those.
  private func followOwnValue() async {
    guard state.followsOwnValue else { return }
    for await change in await store.changes() where change.contains(setting.key) {
      await load()
    }
  }

  /// Reads the switches this row hangs off, then follows them while it is on screen.
  ///
  /// A no-op for the settings that declare none, which is nearly all of them: the `guard`
  /// is what keeps this from being a subscription per row.
  private func followDependency() async {
    let chain = Settings.requirementChain(for: setting)
    guard !chain.isEmpty else { return }
    await readRequirements(chain)
    let keys = Set(chain.map(\.key))
    for await change in await store.changes() {
      guard change.intersects(keys) else { continue }
      await readRequirements(chain)
    }
  }

  private func readRequirements(_ chain: [AnySetting]) async {
    var values: [String: Bool] = [:]
    for parent in chain {
      // A parent of some other type answers nil and is treated as on, which cannot happen:
      // `SettingDependencyTests` refuses a non-Bool parent.
      values[parent.key] = await parent.read(store).boolValue ?? true
    }
    requirementValues = values
  }

  private var hasUnsavedEdit: Bool { state.hasUnsavedEdit }
  private var footnotes: [SettingsFootnote] { state.footnotes }

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
          Button("Generate") { isConfirmingGenerate = true }
            .help("Replace this with a strong random password")
            .controlSize(.small)
            // CONFIRMED, because this is the one irreversible credential rotation in the
            // app and it was the only destructive control that did not ask. Every other one
            // — Revoke, Remove webhook, Cancel message, Disconnect Firebase, Reset
            // integration, Clear FaceTime, Clear log — confirms, which teaches a person that
            // a button here is safe to press and find out.
            //
            // The consequence is stated rather than implied. This file's own comment further
            // down notes that even a NO-OP write of the password disconnects every connected
            // client, so there is no version of this that is quietly recoverable.
            .confirmationDialog(
              "Replace the server password?",
              isPresented: $isConfirmingGenerate,
              titleVisibility: .visible
            ) {
              Button("Replace Password", role: .destructive) {
                draft = PasswordPolicy.generate()
                // REVEALED, because a secret you cannot read is one you cannot put into a
                // client. Generating while masked produces a password the user now has to
                // reset in order to find out what it is.
                isRevealed = true
                // And LOADED: `draft` now holds the real value, which is what that flag
                // means. Left false, the row would keep saying the value is unread and the
                // next `load()` would blank the password it had just minted.
                secretIsLoaded = true
                // Committed immediately: the dialog was the decision, and the checkmark
                // then confirms the new password is live before the user copies it.
                commitDraft()
              }
              Button("Cancel", role: .cancel) {}
            } message: {
              Text(
                "Every connected client will stop working until it is given the new "
                  + "password. The current one cannot be recovered afterwards.")
            }
        }

        HStack(spacing: 6) {
          // Revealable rather than write-only. A user checking whether the password they
          // configured matches the one in their phone has no other way to find out, and
          // hiding it does not protect against anyone who is already sitting at the
          // unlocked machine.
          //
          // The placeholder is the only thing distinguishing "stored, not read" from
          // "nothing here", because an unread secret leaves `draft` empty either way. On
          // macOS a field's title IS its placeholder, so it carries the difference.
          SwiftUI.Group {
            if isRevealed {
              TextField(secretPlaceholder, text: $draft)
            } else {
              SecureField(secretPlaceholder, text: $draft)
            }
          }
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          // The same commit wiring every other field gets. A draft binding without it
          // leaves the password unable to save at all, silently.
          .focused($isEditing)
          .onSubmit { commitDraft() }

          // A LOAD, not a mask toggle, and that is the whole fix. The old button flipped
          // between `SecureField` and `TextField` over a `draft` that `load()` had already
          // filled from the Keychain — so on a build where that read came back empty
          // (see `KeychainSecretStore.withStore`) revealing an empty field revealed
          // nothing, and there was no other way to ask for the value.
          Button {
            if isRevealed {
              hideSecret()
            } else {
              Task { await revealSecret() }
            }
          } label: {
            if isRevealing {
              // The legacy Keychain can put a system panel in front of this, so the button
              // has to show that the click landed rather than looking inert behind it.
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
          }
          .buttonStyle(.borderless)
          // Nothing to reveal: no stored value, and nothing typed either. Live while the
          // person is typing, because revealing what you are entering is half of why the
          // eye is there.
          .disabled(isRevealing || (secretPresence == .absent && draft.isEmpty))
          .help(
            isRevealed
              ? "Hide this again and forget it"
              : "Read this from the Keychain and show it"
          )
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

  /// What an unread secure field shows in place of a value.
  ///
  /// Bullets say "there is something here" without anything having been read; the other two
  /// are the states where bullets would be a lie. Empty once the value is loaded, because
  /// then the field holds the real thing and a placeholder never shows.
  private var secretPlaceholder: String {
    guard setting.isSecret, !secretIsLoaded else { return "" }
    switch secretPresence {
    case .stored: return "••••••••"
    case .absent: return "Not set"
    case .unreadable: return "Keychain unavailable"
    }
  }

  private var displayValue: String { state.displayValue }
  private var passwordAdvice: String? { state.passwordAdvice }

  private func load() async {
    // A secret is read only once somebody has asked. See the `secretPresence` comment.
    if setting.isSecret {
      secretPresence = await setting.presence(store)
      // `setting.source(store)` would resolve the value to answer this, which is the read
      // being avoided. Presence knows the same thing: an override is a lookup in two
      // dictionaries, and everything else is the persisted layer or nothing.
      source = secretPresence.source ?? .declaredDefault
      guard secretIsLoaded else { return }
    }
    value = await setting.read(store)
    source = await setting.source(store)
    syncDraft()
  }

  /// Reads the secret out of the Keychain and shows it.
  ///
  /// The one place in this view that materialises a secret, and it runs on a click.
  private func revealSecret() async {
    guard setting.isSecret, !secretIsLoaded else {
      isRevealed = true
      return
    }
    // A draft the person is part-way through typing is theirs, not the Keychain's.
    // Overwriting it with the stored value would discard an edit in order to show what is
    // being replaced, which is the opposite of what pressing the eye asks for.
    guard !hasUnsavedEdit else {
      isRevealed = true
      return
    }

    isRevealing = true
    defer { isRevealing = false }

    let stored = await setting.read(store)
    secretPresence = await setting.presence(store)

    // THE READ FAILING IS NOT THE READ RETURNING NOTHING, and `unreadableSecretKeys` is the
    // only thing that can tell them apart here. `read` resolves an unreadable secret to the
    // declared default, because `resolve` has nowhere to put "unknown" — so it hands back
    // `""`, exactly like a secret that is genuinely set to the empty string, which is a
    // state the store supports and `remove` goes out of its way to distinguish. Inferring
    // "unreadable" from emptiness would report a Keychain fault for an empty password.
    //
    // Worth the care: the reasonable response to a blank password field is Generate, and
    // Generate is the one irreversible thing on this page. That store property has said
    // "the settings screen above all" since it was written, and nothing was asking it.
    if await store.unreadableSecretKeys.contains(setting.key) {
      error =
        "The Keychain would not return this value. It has not been lost; do not "
        + "replace it until the Keychain is reachable."
      return
    }

    value = stored
    draft = stored.stringValue ?? ""
    secretIsLoaded = true
    isRevealed = true
  }

  /// Hides a revealed secret, and forgets it again.
  ///
  /// Not just a mask: the value goes back out of `draft`, so the next reveal is a fresh
  /// read and the plaintext is not sitting in view state for the rest of the session. Kept
  /// when there is an uncommitted edit, which is the person's own text rather than the
  /// Keychain's.
  private func hideSecret() {
    isRevealed = false
    guard setting.isSecret, secretIsLoaded, !hasUnsavedEdit else { return }
    secretIsLoaded = false
    value = nil
    draft = ""
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
        // A secret the person just typed is one they already know, and `draft` holds it.
        // Without this the row would reload into the unread state, blank the field they
        // are looking at, and go on showing "Not saved yet" for a write that landed.
        if setting.isSecret { secretIsLoaded = true }
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
