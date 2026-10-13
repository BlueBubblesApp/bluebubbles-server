//  ServiceFormView
//  A service's configuration, rendered from its manifest.
//
//  The counterpart to `SettingsView`: that screen is generated from settings compiled into the
//  binary, this one from a manifest that may have arrived as JSON. They deliberately look the
//  same to a user: both are built from `SettingsLayout`, so a plugin's configuration is not
//  visibly second-class, but nothing here reads a `Setting<Value>`, because a plugin has none.
//
//  Two things this renders that the core settings screen cannot:
//
//    - **Display elements.** Headers, paragraphs, notes and dividers carry no value. A form is
//      not a list of fields: zrok's setup needs a paragraph explaining what an account token is
//      and where to get one, and without somewhere to put it that explanation ends up crammed
//      into a field's help text or dropped.
//    - **Conditional fields.** `visibleWhen` hides the reserved-share inputs until reserving is
//      switched on. Shown unconditionally they invite someone to fill in a value that is then
//      ignored, which is how the old settings page behaved.
//
//  A `.header` starts a new card rather than drawing bold text inside one. That is what makes a
//  long manifest legible: zrok's twelve elements read as "Account", "Tunnel", "Advanced"
//  instead of one unbroken column, and it costs a manifest author nothing they were not
//  already writing.
//
//  TEXT IS EDITED AS A DRAFT AND COMMITTED ON RETURN OR FOCUS LOSS, exactly as `SettingRow`
//  does, and here the reason is sharper than there. Every proxy service watches its own
//  fields and answers a change with `.restart`, so a form that wrote the store per keystroke
//  restarted the selected tunnel once per character typed into its token field, and each of
//  those partial tokens was handed to the vendor's binary. A click is a finished decision, so
//  toggles, pickers, dates and the path chooser commit at once; a keystroke is one letter of
//  one, so text waits for Return, for focus to move, or for the host's Done
//  (`commitRequest`). Leaving the page does NOT write: a form being torn down cannot show
//  what a write refused, so an uncommitted edit is kept on `SettingsModel` and comes back,
//  still marked unsaved, when the form is next opened.
//
//  THE CONTROLS ARE THE SETTINGS ROW'S (`SettingControls.swift`), and so is the lifecycle
//  around them: a refused write snaps the control back to what is stored and says why under
//  the field, and the Keychain is described in `SecretFieldPolicy`'s words. Two copies of
//  one control lifecycle drift, and the copy nobody is looking at is the one that is wrong.
//
//  FOLLOWED, NOT READ ONCE. The form reads again on every write to its manifest's namespace
//  (`SettingsModel.version(inNamespace:)`): a reset, the API, `--set`, onboarding and the
//  service itself (zrok records its reservation) all write these keys, and a form that read
//  only on appear went on showing what was there before. A field holding an edit keeps it
//  across the re-read; every other field takes the stored value. A read that fails says so
//  above the fields and leaves them untouchable, rather than drawing blanks that a click
//  would then write over a value that is still stored.
//
//  This emits sections, NOT a page: it is placed inside a host that already scrolls, and a
//  scroll view nested in a scroll view traps the wheel over whichever one the pointer is on.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import BBCore
import BBServiceKit
import BBSettings
import SwiftUI

struct ServiceFormView: View {

  let manifest: ServiceManifest
  let model: AppModel
  /// Bumped by a host's Done button to commit every field still holding an edit. A host
  /// that is a page rather than a sheet leaves it alone.
  var commitRequest = 0
  /// Called once a `commitRequest` has committed everything. Not called when a field was
  /// refused: the host stays open, with the refusal beside the field and in the alerts.
  var onCommitted: () -> Void = {}

  /// Every field's current value as the form shows it, keyed by the field's RELATIVE name.
  ///
  /// Relative rather than fully qualified because `visibleWhen` names a sibling field, and
  /// resolving a condition would otherwise mean re-deriving the namespace on every keystroke.
  ///
  /// This is the DRAFT. For a text field it can run ahead of the store while the person is
  /// typing; `committed` is what the store holds.
  @State private var values: [String: String] = [:]
  /// What the store last accepted, so a commit that changes nothing is skipped: tabbing
  /// through a page must not rewrite every field, and a no-op write of a token would still
  /// restart the tunnel.
  @State private var committed: [String: String] = [:]

  // A SECRET FIELD IS READ WHEN SOMEBODY ASKS FOR IT, AND NOT WHEN THE FORM OPENS.
  //
  // The same rule `SettingRow` follows, for the same reasons and through the same control,
  // `SecretField`: the resting state of an ngrok, zrok or ntfy token field is bullets nothing
  // read, and the eye performs the read. `load()` asks `presence` instead, which tells the
  // field whether anything is stored without materialising it — no access panel on the
  // legacy Keychain, and no token sitting in `values` for the life of the sheet.
  /// What is known about each secret field without reading it, by relative field key.
  @State private var secretPresence: [String: SecretPresence] = [:]
  /// The secret fields whose value has actually been read into `values`.
  @State private var loadedSecrets: Set<String> = []
  /// Which collapsed sections the user has opened, by title.
  ///
  /// View state, deliberately NOT a stored setting: whether someone expanded "Advanced" a
  /// moment ago is not configuration, and writing it into the service's namespace would put
  /// a key nothing reads next to the ones that decide how the tunnel runs.
  @State private var expanded: Set<String> = []
  /// Why the last write of a field was refused, by field key: shown under it, as a settings
  /// row shows its own.
  @State private var errors: [String: String] = [:]
  /// Why the form could not be read. While there is one the fields are drawn but cannot be
  /// touched: a blank where a value could not be read is not a value anybody chose.
  @State private var loadError: String?
  /// The field whose write just landed, for its tick.
  @State private var justSaved: String?
  /// The text field being edited, by field key. Focus leaving one is its commit.
  @FocusState private var editing: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
      if let loadError {
        ErrorLine(loadError)
      }
      ForEach(groups) { group in
        // A group whose every field is hidden by `visibleWhen` is dropped entirely
        // rather than left as an empty card, which would read as a rendering fault.
        let visible = ServiceFormLayout.visibleElements(in: group, values: values)
        if !visible.isEmpty {
          let title = group.title ?? "Configuration"
          SettingsSection(title) {
            if !group.isCollapsed || expanded.contains(title) {
              ForEach(visible) { entry in
                if entry.needsDivider { SettingsDivider() }
                render(entry.element)
              }
            } else {
              // The card stays, holding one line that says what is inside it.
              // Collapsing the header away entirely would leave the user with no
              // sign that there is anything here to open.
              Text(ServiceFormLayout.summary(of: visible))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          } trailing: {
            disclosureControl(for: group)
          }
          .disabled(loadError != nil)
        }
      }
    }
    // Read on appear and again on every write to this manifest's settings, from anywhere.
    .task(id: namespaceVersion) { await load() }
    // Focus moving off a text field commits it. Clicking away is how macOS says "done
    // with this one", and it is the case a Save button would exist to catch.
    .onChange(of: editing) { previous, _ in
      if let previous { commit(previous) }
    }
    // Done, in a sheet. A click on a button does not take focus from the field being
    // edited, so without this the last field typed in would be the one not saved.
    .onChange(of: commitRequest) {
      Task {
        if await commitAll() { onCommitted() }
      }
    }
    // Navigating away KEEPS an uncommitted edit rather than writing it. Dropping it is the
    // one outcome worse than saving too eagerly, and writing it is a write whose refusal
    // nobody would see.
    .onDisappear { keepUncommittedDrafts() }
  }

  /// Moves on every write to this manifest's own settings. The model does the following; a
  /// view never subscribes on its own.
  private var namespaceVersion: UInt64 {
    model.settings.version(inNamespace: manifest.id.rawValue + ".")
  }

  // MARK: - Grouping

  /// The layout rules — grouping, dividers, and which fields a condition admits — are
  /// `ServiceFormLayout`, not `private func`s here. A manifest author writes against them
  /// and a test could not reach them while they sat on a View.
  private typealias Group = ServiceFormLayout.Group
  private typealias Entry = ServiceFormLayout.Entry

  private var groups: [Group] { ServiceFormLayout.groups(of: manifest.settings) }

  /// The show/hide button on a collapsed section's header, and nothing at all on any other.
  @ViewBuilder
  private func disclosureControl(for group: Group) -> some View {
    if group.isCollapsed, let title = group.title {
      let isOpen = expanded.contains(title)
      Button {
        if isOpen { expanded.remove(title) } else { expanded.insert(title) }
      } label: {
        Label(isOpen ? "Hide" : "Show", systemImage: isOpen ? "chevron.up" : "chevron.down")
          .labelStyle(.titleAndIcon)
          .font(.callout)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(isOpen ? "Hide \(title)" : "Show \(title)")
    }
  }

  @ViewBuilder
  private func render(_ element: FormElement) -> some View {
    switch element {
    case .header(let text), .collapsedHeader(let text):
      // Only reachable for a nested header a manifest emits after grouping; rendered
      // inline rather than dropped.
      Text(text).font(.headline).padding(.top, 8)

    case .paragraph(let text):
      // A minimal Markdown subset, so a manifest can emphasise a word or link to a
      // sign-up page without being able to inject arbitrary presentation.
      Text(markdown(text))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)

    case .note(let text):
      Label {
        Text(markdown(text)).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "info.circle").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)

    case .divider:
      SettingsDivider()

    case .field(let field):
      fieldRow(field)
    }
  }

  // MARK: - Fields

  @ViewBuilder
  private func fieldRow(_ field: FieldDescriptor) -> some View {
    switch field.kind {
    // Controls that need the width get a stacked row; everything else gets the two-column
    // label-and-control shape the core settings screen uses.
    case .paragraph:
      SettingsWideRow(title: field.label, help: field.help) {
        // No Return to commit here (Return is a newline in a text editor) so focus loss
        // and leaving the page are the commit points.
        TextEditor(text: draft(field))
          .frame(minHeight: 96)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(6)
          .glassSurface(cornerRadius: SettingsMetrics.fieldCornerRadius)
          .focused($editing, equals: field.key)
        // A secret paragraph (PEM text) is never read back into the editor: `load` records
        // that one is stored and nothing more, and its footnote says so.
        ForEach(footnotes(for: field)) { note in note }
      }

    case .multiSelect(let options):
      SettingsWideRow(title: field.label, help: field.help) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(options, id: \.value) { option in
            Toggle(option.label, isOn: Binding(contains: option.value, in: selection(field)))
              .toggleStyle(.checkbox)
          }
        }
        ForEach(footnotes(for: field)) { note in note }
      }

    // The SAME picker the webhook editor uses, not a second vocabulary for the same
    // events. It draws its own "Send" row, so it goes in without a `SettingsWideRow`
    // title around it; the manifest's label would otherwise appear twice.
    case .eventSubscription:
      VStack(alignment: .leading, spacing: 0) {
        EventSubscriptionPicker(
          subscription: eventBinding(field),
          emptyWarning: "Nothing is published to the topic while no event is selected."
        )
        ForEach(footnotes(for: field)) { note in note }
      }

    default:
      SettingsRow(
        title: field.label,
        help: field.help,
        // Required and empty, said plainly. A service that will not start because a
        // field is blank should say so HERE, next to the field, rather than only in a
        // log line the user never sees.
        footnotes: footnotes(for: field),
        controlWidth: ServiceFormLayout.reservesControlColumn(field)
          ? SettingsMetrics.controlWidth : nil
      ) {
        control(for: field)
          .disabled(ServiceFormLayout.isDisabled(field, values: values))
          .labelsHidden()
      }
    }
  }

  /// What is said under a field.
  ///
  /// The disabled reason takes precedence over "Required.": a field that cannot be edited
  /// cannot be filled in either, so demanding a value would be telling the user to do
  /// something the form has just stopped them doing. An unsaved draft is named too, and
  /// neutrally: it appears on the first keystroke of a perfectly ordinary edit, and
  /// colouring it as a problem would make typing look like a fault.
  private func footnotes(for field: FieldDescriptor) -> [SettingsFootnote] {
    ServiceFormLayout.footnotes(
      for: field, values: values, committed: committed, writeError: errors[field.key],
      secret: field.isSecret
        ? SecretFieldPolicy.note(
          for: storedState(field),
          isLoaded: loadedSecrets.contains(field.key) || !isBlank(field),
          revealable: field.kind != .paragraph)
        : nil)
  }

  /// The settings row's controls, over this form's string-valued fields.
  @ViewBuilder
  private func control(for field: FieldDescriptor) -> some View {
    switch field.kind {
    case .toggle(let fallback):
      SettingToggleControl(isOn: immediate(field, default: String(fallback)).isTrue)

    case .text(let placeholder):
      secureOrPlain(field, placeholder: placeholder)

    case .url:
      secureOrPlain(field, placeholder: "https://…")

    case .number(let range):
      SettingNumberControl(
        value: numberDraft(field), range: range, focus: $editing, focusKey: field.key,
        onSubmit: { commit(field.key) }, onStep: { _ in commit(field.key) },
        justSaved: justSaved == field.key)

    case .decimal:
      SettingTextControl(
        text: draft(field), focus: $editing, focusKey: field.key,
        onSubmit: { commit(field.key) }, justSaved: justSaved == field.key)

    case .date:
      DatePicker("", selection: dateBinding(field), displayedComponents: [.date])
        .controlSize(.large)

    case .select(let options):
      SettingPickerControl(
        selection: immediate(field),
        options: options.map { .init(value: $0.value, label: $0.label) })

    case .path:
      HStack(spacing: 8) {
        Text(values[field.key] ?? "Not set")
          .foregroundStyle((values[field.key] ?? "").isEmpty ? .secondary : .primary)
          .lineLimit(1).truncationMode(.middle)
        Button("Choose…") { choosePath(for: field) }
      }

    // Handled by `fieldRow` as wide rows; unreachable here.
    case .paragraph, .multiSelect, .eventSubscription:
      EmptyView()
    }
  }

  @ViewBuilder
  private func secureOrPlain(_ field: FieldDescriptor, placeholder: String?) -> some View {
    if field.isSecret {
      // Revealable, because a user pasting a token needs to be able to check it: and a
      // write-only field they cannot verify is where "it says it's saved but it does not
      // work" comes from. The manifest's placeholder still wins once nothing is stored: it
      // is the field-specific hint, and "Not set" says less than "ngrok authtoken".
      SecretField(
        presence: SecretFieldState(
          presence: storedState(field), isLoaded: loadedSecrets.contains(field.key),
          fallback: placeholder ?? ""),
        text: draft(field),
        focus: $editing,
        focusKey: field.key,
        onSubmit: { commit(field.key) },
        reveal: { await revealSecret(field) },
        forget: { forgetSecret(field) },
        accessory: { SavedIndicator(isVisible: justSaved == field.key) }
      )
    } else {
      SettingTextControl(
        text: draft(field), placeholder: placeholder ?? "", focus: $editing,
        focusKey: field.key, onSubmit: { commit(field.key) },
        justSaved: justSaved == field.key)
    }
  }

  /// What is known about a secret field without reading it; `.absent` until `load` says.
  private func storedState(_ field: FieldDescriptor) -> SecretPresence {
    secretPresence[field.key] ?? .absent
  }

  private func isBlank(_ field: FieldDescriptor) -> Bool {
    (values[field.key] ?? "").isEmpty
  }

  /// Reads one secret field out of the Keychain, for the eye. Answers whether there is now
  /// something to show.
  private func revealSecret(_ field: FieldDescriptor) async -> Bool {
    // Already read; or a value the person is part-way through typing, which is theirs: do
    // not overwrite it with the stored one in order to show what it is replacing.
    guard field.isSecret, !loadedSecrets.contains(field.key), isBlank(field) else {
      return true
    }

    let key = manifest.storageKey(for: field.key)
    do {
      let stored = try await model.settings.string(forKey: key) ?? ""
      secretPresence[field.key] = try await model.settings.presence(ofSecretKey: key)

      // A failed read, asked rather than inferred. `string(forKey:)` answers `nil` both for
      // a Keychain that refused and for a key that holds nothing, and a token legitimately
      // set to the empty string is a third thing that looks the same; `isUnreadable` is the
      // only one of the three that is a fault. Reporting a blank field as a Keychain failure
      // would send the user off to mint a replacement token they did not need.
      if try await model.settings.isUnreadable(key) {
        // NOT reported again from here. `SettingsStore.readSecret` has already raised the
        // real failure, with the real `OSStatus`, once per key per episode — a second alert
        // from this view would either duplicate it or invent a status it does not know. The
        // field saying "Keychain unavailable" is this layer's whole job.
        secretPresence[field.key] = .unreadable
        return false
      }

      values[field.key] = stored
      committed[field.key] = stored
      loadedSecrets.insert(field.key)
      return true
    } catch {
      errors[field.key] = DiagnosticText.sentence(for: error)
      return false
    }
  }

  /// Forgets a revealed secret field again, as it is hidden.
  ///
  /// The value leaves `values`, so the next reveal is a fresh read rather than a mask being
  /// lifted off a token this sheet has been holding all along. An uncommitted edit stays:
  /// it is the person's text, not the store's.
  private func forgetSecret(_ field: FieldDescriptor) {
    guard loadedSecrets.contains(field.key) else { return }
    guard (values[field.key] ?? "") == (committed[field.key] ?? "") else { return }
    loadedSecrets.remove(field.key)
    values[field.key] = ""
    committed[field.key] = ""
  }

  // MARK: - Values

  /// A binding onto the draft alone. Nothing reaches the store until `commit`.
  private func draft(_ field: FieldDescriptor) -> Binding<String> {
    Binding(
      get: { values[field.key] ?? "" },
      set: { values[field.key] = $0 }
    )
  }

  /// A number field's draft as a number.
  ///
  /// A field with nothing stored shows 0 and holds the empty string, and it must go on
  /// holding it until somebody types: setting a number equal to the one shown is not an
  /// edit, so clicking into the field and away does not write 0 over "not set". The range is
  /// not clamped here; a number outside it is refused with a reason under the field
  /// (`ServiceFormLayout.validationFailure`), as the store refuses one for a setting.
  private func numberDraft(_ field: FieldDescriptor) -> Binding<Int> {
    Binding(
      get: { Int(values[field.key] ?? "") ?? 0 },
      set: { newValue in
        guard newValue != (Int(values[field.key] ?? "") ?? 0) else { return }
        values[field.key] = String(newValue)
      }
    )
  }

  /// A binding that commits as it changes, for controls where a change IS a decision:
  /// a switch, a picker, a checkbox, a date, a file chooser.
  private func immediate(_ field: FieldDescriptor, default fallback: String = "")
    -> Binding<String>
  {
    Binding(
      get: { values[field.key] ?? fallback },
      set: { newValue in
        values[field.key] = newValue
        commit(field.key)
      }
    )
  }

  private func dateBinding(_ field: FieldDescriptor) -> Binding<Date> {
    Binding(
      get: {
        // ISO 8601, because a date in a settings store crosses process boundaries and
        // a locale-formatted one would parse differently on another Mac.
        guard let raw = values[field.key], let date = ISO8601DateFormatter().date(from: raw)
        else { return Date() }
        return date
      },
      set: { newValue in
        values[field.key] = ISO8601DateFormatter().string(from: newValue)
        commit(field.key)
      }
    )
  }

  /// An event subscription's stored comma-separated form, as the picker's value.
  ///
  /// Written straight through on every change, like a multi-select's ticks: this sheet saves
  /// as you go, and an events picker that waited for a Done would be the one control on the
  /// form that did.
  private func eventBinding(_ field: FieldDescriptor) -> Binding<EventSubscription> {
    Binding(
      get: { EventSubscription(settingValue: values[field.key] ?? "") },
      set: { subscription in
        values[field.key] = subscription.settingValue
        commit(field.key)
      }
    )
  }

  /// A multi-select's chosen options as a set, stored as one comma-separated value and
  /// committed as it changes: a tick is a finished decision.
  private func selection(_ field: FieldDescriptor) -> Binding<Set<String>> {
    Binding(
      get: { ServiceFormLayout.selected(field, values: values) },
      set: { chosen in
        values[field.key] = chosen.sorted().joined(separator: ",")
        commit(field.key)
      }
    )
  }

  /// Reads every field. On a re-read, a field holding an edit keeps it: the write that
  /// moved the namespace was somebody else's field, or this form's own commit of another.
  private func load() async {
    var loaded: [String: String] = [:]
    var presence: [String: SecretPresence] = [:]
    do {
      for field in manifest.fields {
        let key = manifest.storageKey(for: field.key)
        // A SECRET IS NOT READ HERE. `string(forKey:)` would materialise the token — and on
        // the legacy Keychain raise an access panel for it — every time this sheet opened,
        // for a value the person has not asked to see. Presence answers what the field
        // needs to draw itself; `revealSecret` does the read, on a click.
        if field.isSecret {
          presence[field.key] = try await model.settings.presence(ofSecretKey: key)
          // A secret the person has revealed is read again, because they are looking at
          // it: blanking the field under them would read as the token disappearing, and
          // keeping what was read before would show a token a reset or another writer has
          // since replaced.
          if loadedSecrets.contains(field.key) {
            loaded[field.key] = try await model.settings.string(forKey: key) ?? ""
          }
          continue
        }
        if let value = try await model.settings.string(forKey: key) {
          loaded[field.key] = value
        }
      }
    } catch {
      // Said above the fields, which stay untouchable until a read succeeds: blanks drawn
      // over values that could not be read invite a write over values that are still there.
      loadError =
        "The \(manifest.name) settings could not be read. "
        + DiagnosticText.sentence(for: error)
      return
    }
    loadError = nil
    var next = loaded
    for field in manifest.fields where hasEdit(field) {
      next[field.key] = values[field.key]
    }
    values = next
    committed = loaded
    secretPresence = presence
    // An edit kept from the last time this form was torn down, typed over the value that is
    // still stored, goes back into its field, still unsaved.
    for field in manifest.fields {
      if let kept = model.settings.takeDraft(
        for: manifest.storageKey(for: field.key), ifStillOver: draftBase(field))
      {
        values[field.key] = kept
      }
    }
  }

  /// Whether a field holds something the store has not been given.
  private func hasEdit(_ field: FieldDescriptor) -> Bool {
    (values[field.key] ?? "") != (committed[field.key] ?? "")
  }

  /// What a kept edit of `field` was typed over. The empty string for a secret, which is not
  /// read to be compared: a token the person typed is theirs whatever the Keychain now holds.
  private func draftBase(_ field: FieldDescriptor) -> String {
    field.isSecret ? "" : committed[field.key] ?? ""
  }

  private func keepUncommittedDrafts() {
    for field in manifest.fields where hasEdit(field) {
      model.settings.keepDraft(
        values[field.key] ?? "", typedOver: draftBase(field),
        for: manifest.storageKey(for: field.key))
    }
  }

  // MARK: - Committing

  /// Writes one field's draft to the store, if it actually differs from what is stored.
  ///
  /// The equality check is what makes commit-on-blur quiet, and, for this form, what keeps a
  /// tunnel up: every proxy restarts on a change to its own fields, so a write that changed
  /// nothing would still cost a reconnect and a new address.
  private func commit(_ key: String) {
    guard let field = manifest.fields.first(where: { $0.key == key }) else { return }
    let value = values[key] ?? ""
    guard value != (committed[key] ?? "") else { return }
    Task { await save(field, value) }
  }

  /// Commits every field holding an edit, for Done. Answers whether all of them landed.
  private func commitAll() async -> Bool {
    var allLanded = true
    for field in manifest.fields {
      let value = values[field.key] ?? ""
      guard value != (committed[field.key] ?? "") else { continue }
      if await !save(field, value) { allLanded = false }
    }
    return allLanded
  }

  /// Writes one field. Answers whether it landed.
  @discardableResult
  private func save(_ field: FieldDescriptor, _ value: String) async -> Bool {
    // Refused before it is stored, not after the service has tried to use it.
    //
    // **This guard is the refusal, and for a long time only the comment was here.** The
    // sentence above described it, `ServiceFormLayout.validationFailure` existed and was
    // unit-tested in isolation, and nothing connected the two: `save` went straight to
    // `store.set`. So an invalid value was written, the service restarted on the change to
    // its own field, and the person got a red footnote under a value that had already been
    // saved. The sibling comment in `ProxyService` costs that out at 175 refusals in 71
    // seconds for an invalid zrok reserved name.
    //
    // The footnote is already saying why, so this returns quietly rather than raising a
    // second report of the same thing. The draft is left in `values` deliberately: clearing
    // it would throw away what the person typed while telling them to correct it.
    guard ServiceFormLayout.validationFailure(field, values: values) == nil else { return false }

    let key = manifest.storageKey(for: field.key)
    do {
      try await model.settings.set(value, forKey: key, isSecret: field.isSecret)
      committed[field.key] = value
      errors[field.key] = nil
      model.settings.discardDraft(for: key)
      flashSaved(field.key)
      return true
    } catch {
      // Under the field, in the store's own words, as a settings row says it. And back to
      // what the store holds, beside the sentence saying why: a switch left flipped over a
      // refused write reads as a setting that took.
      errors[field.key] = DiagnosticText.sentence(for: error)
      values[field.key] = committed[field.key]
      return false
    }
  }

  private func flashSaved(_ key: String) {
    justSaved = key
    Task {
      try? await Task.sleep(for: .seconds(1.6))
      if justSaved == key { justSaved = nil }
    }
  }

  private func choosePath(for field: FieldDescriptor) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    values[field.key] = url.path
    commit(field.key)
  }

  /// Renders the Markdown subset a manifest may use, falling back to the literal text.
  ///
  /// Failing back rather than throwing matters for a third-party manifest: a malformed link
  /// should show as the characters someone typed, not blank out the paragraph explaining how
  /// to configure the thing.
  private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
  }
}

extension Binding where Value == String {
  /// A string binding viewed as a toggle, since manifest values are stored as text.
  fileprivate var isTrue: Binding<Bool> {
    Binding<Bool>(
      get: { wrappedValue == "true" },
      set: { wrappedValue = $0 ? "true" : "false" }
    )
  }
}
