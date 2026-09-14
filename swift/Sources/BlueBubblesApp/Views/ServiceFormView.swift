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
//  one, so text waits for Return, for focus to move, or for the page to close.
//
//  This emits sections, NOT a page: it is placed inside a host that already scrolls, and a
//  scroll view nested in a scroll view traps the wheel over whichever one the pointer is on.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import BBServiceKit
import BBSettings
import SwiftUI

struct ServiceFormView: View {

  let manifest: ServiceManifest
  let store: SettingsStore
  let model: AppModel

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
  @State private var revealed: Set<String> = []

  // A SECRET FIELD IS READ WHEN SOMEBODY ASKS FOR IT, AND NOT WHEN THE FORM OPENS.
  //
  // The same rule `SettingRow` follows, for the same reasons and with the same shape: the
  // resting state of an ngrok, zrok or ntfy token field is bullets nothing read, and the eye
  // performs the read. `load()` asks `presence` instead, which tells the field whether
  // anything is stored without materialising it — no access panel on the legacy Keychain,
  // and no token sitting in `values` for the life of the sheet.
  /// What is known about each secret field without reading it, by relative field key.
  @State private var secretPresence: [String: SecretPresence] = [:]
  /// The secret fields whose value has actually been read into `values`.
  @State private var loadedSecrets: Set<String> = []
  /// The field currently being read, so its button can say the click landed.
  @State private var revealing: String?
  /// Which collapsed sections the user has opened, by title.
  ///
  /// View state, deliberately NOT a stored setting: whether someone expanded "Advanced" a
  /// moment ago is not configuration, and writing it into the service's namespace would put
  /// a key nothing reads next to the ones that decide how the tunnel runs.
  @State private var expanded: Set<String> = []
  /// The text field being edited, by field key. Focus leaving one is its commit.
  @FocusState private var editing: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
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
        }
      }
    }
    .task { await load() }
    // Focus moving off a text field commits it. Clicking away is how macOS says "done
    // with this one", and it is the case a Save button would exist to catch.
    .onChange(of: editing) { previous, _ in
      if let previous { commit(previous) }
    }
    // Navigating away commits too. Without it, switching pages mid-edit drops the change
    // on the floor: the one outcome worse than saving too eagerly.
    .onDisappear { commitAll() }
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
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
          .focused($editing, equals: field.key)
        ForEach(footnotes(for: field)) { note in note }
      }

    case .multiSelect(let options):
      SettingsWideRow(title: field.label, help: field.help) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(options, id: \.value) { option in
            Toggle(option.label, isOn: multiBinding(field, option: option.value))
              .toggleStyle(.checkbox)
          }
        }
        ForEach(footnotes(for: field)) { note in note }
      }

    default:
      SettingsRow(
        title: field.label,
        help: field.help,
        // Required and empty, said plainly. A service that will not start because a
        // field is blank should say so HERE, next to the field, rather than only in a
        // log line the user never sees.
        footnotes: footnotes(for: field)
      ) {
        control(for: field)
          .disabled(ServiceFormLayout.isDisabled(field, values: values))
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
    ServiceFormLayout.footnotes(for: field, values: values, committed: committed)
  }

  @ViewBuilder
  private func control(for field: FieldDescriptor) -> some View {
    switch field.kind {
    case .toggle:
      Toggle("", isOn: immediate(field, default: "false").isTrue)
        .toggleStyle(.switch)
        .labelsHidden()

    case .text(let placeholder):
      secureOrPlain(field, placeholder: placeholder)

    case .url:
      secureOrPlain(field, placeholder: "https://…")

    case .number(let range):
      TextField("", text: draft(field))
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .frame(width: 140)
        .focused($editing, equals: field.key)
        .onSubmit { commit(field.key) }
        .onChange(of: values[field.key] ?? "") { _, new in
          // Digits only, clamped as typed. Letting a non-number through would
          // store a value the service reads back as zero.
          let digits = new.filter { $0.isNumber || $0 == "-" }
          var clamped = digits
          if let range, let value = Int(digits) {
            clamped = String(min(max(value, range.lowerBound), range.upperBound))
          }
          if clamped != new { values[field.key] = clamped }
        }

    case .decimal:
      TextField("", text: draft(field))
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .frame(width: 140)
        .focused($editing, equals: field.key)
        .onSubmit { commit(field.key) }

    case .date:
      DatePicker("", selection: dateBinding(field), displayedComponents: [.date])
        .labelsHidden()
        .controlSize(.large)

    case .select(let options):
      Picker("", selection: immediate(field)) {
        ForEach(options, id: \.value) { option in
          Text(option.label).tag(option.value)
        }
      }
      .labelsHidden()
      .controlSize(.large)
      .frame(maxWidth: 240)

    case .path:
      HStack(spacing: 8) {
        Text(values[field.key] ?? "Not set")
          .foregroundStyle((values[field.key] ?? "").isEmpty ? .secondary : .primary)
          .lineLimit(1).truncationMode(.middle)
        Button("Choose…") { choosePath(for: field) }
      }

    // Handled by `fieldRow` as wide rows; unreachable here.
    case .paragraph, .multiSelect:
      EmptyView()
    }
  }

  @ViewBuilder
  private func secureOrPlain(_ field: FieldDescriptor, placeholder: String?) -> some View {
    HStack(spacing: 6) {
      SwiftUI.Group {
        if field.isSecret, !revealed.contains(field.key) {
          SecureField(prompt(field, placeholder), text: draft(field))
        } else {
          TextField(prompt(field, placeholder), text: draft(field))
        }
      }
      .textFieldStyle(.roundedBorder)
      .controlSize(.large)
      .focused($editing, equals: field.key)
      .onSubmit { commit(field.key) }

      if field.isSecret {
        // Revealable, because a user pasting a token needs to be able to check it:
        // and a write-only field they cannot verify is where "it says it's saved but
        // it does not work" comes from.
        //
        // And a LOAD rather than a mask toggle, because the form no longer reads the token
        // when it opens. Unrevealed, the field holds nothing; this is what fetches it.
        Button {
          if revealed.contains(field.key) {
            hideSecret(field)
          } else {
            Task { await revealSecret(field) }
          }
        } label: {
          if revealing == field.key {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: revealed.contains(field.key) ? "eye.slash" : "eye")
          }
        }
        .buttonStyle(.borderless)
        .disabled(revealing != nil || (storedState(field) == .absent && isBlank(field)))
        .help(
          revealed.contains(field.key)
            ? "Hide this again and forget it"
            : "Read this from the Keychain and show it"
        )
        .accessibilityLabel(revealed.contains(field.key) ? "Hide" : "Reveal")
      }
    }
  }

  /// What an unread secret field shows in place of a value.
  ///
  /// A manifest's own placeholder still wins once there is nothing stored — it is the
  /// field-specific hint, and "Not set" says less than "ngrok authtoken". Bullets replace it
  /// only when something IS stored and has not been read, where the manifest's hint would
  /// read as an empty field.
  private func prompt(_ field: FieldDescriptor, _ placeholder: String?) -> String {
    guard field.isSecret, !loadedSecrets.contains(field.key) else { return placeholder ?? "" }
    switch storedState(field) {
    case .stored: return "••••••••"
    case .unreadable: return "Keychain unavailable"
    case .absent: return placeholder ?? ""
    }
  }

  /// What is known about a secret field without reading it; `.absent` until `load` says.
  private func storedState(_ field: FieldDescriptor) -> SecretPresence {
    secretPresence[field.key] ?? .absent
  }

  private func isBlank(_ field: FieldDescriptor) -> Bool {
    (values[field.key] ?? "").isEmpty
  }

  /// Reads one secret field out of the Keychain and shows it.
  private func revealSecret(_ field: FieldDescriptor) async {
    revealed.insert(field.key)
    guard field.isSecret, !loadedSecrets.contains(field.key) else { return }
    // A value the person is part-way through typing is theirs; do not overwrite it with
    // the stored one in order to show what it is replacing.
    guard isBlank(field) else { return }

    revealing = field.key
    defer { revealing = nil }

    let key = manifest.storageKey(for: field.key)
    let stored = await store.string(forKey: key) ?? ""
    secretPresence[field.key] = await store.presence(ofSecretKey: key)

    // A failed read, asked rather than inferred. `string(forKey:)` answers `nil` both for a
    // Keychain that refused and for a key that holds nothing, and a token legitimately set
    // to the empty string is a third thing that looks the same; `unreadableSecretKeys` is
    // the only one of the three that is a fault. Reporting a blank field as a Keychain
    // failure would send the user off to mint a replacement token they did not need.
    if await store.unreadableSecretKeys.contains(key) {
      // NOT reported again from here. `SettingsStore.readSecret` has already raised the
      // real failure, with the real `OSStatus`, once per key per episode — a second alert
      // from this view would either duplicate it or invent a status it does not know. The
      // field saying "Keychain unavailable" is this layer's whole job.
      secretPresence[field.key] = .unreadable
      return
    }

    values[field.key] = stored
    committed[field.key] = stored
    loadedSecrets.insert(field.key)
  }

  /// Hides a revealed secret field, and forgets it again.
  ///
  /// The value leaves `values`, so the next reveal is a fresh read rather than a mask being
  /// lifted off a token this sheet has been holding all along. An uncommitted edit stays:
  /// it is the person's text, not the store's.
  private func hideSecret(_ field: FieldDescriptor) {
    revealed.remove(field.key)
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

  /// One option of a multi-select, stored as a comma-separated list.
  private func multiBinding(_ field: FieldDescriptor, option: String) -> Binding<Bool> {
    Binding(
      get: { ServiceFormLayout.selected(field, values: values).contains(option) },
      set: { isOn in
        var current = ServiceFormLayout.selected(field, values: values)
        if isOn { current.insert(option) } else { current.remove(option) }
        values[field.key] = current.sorted().joined(separator: ",")
        commit(field.key)
      }
    )
  }

  private func load() async {
    var loaded: [String: String] = [:]
    var presence: [String: SecretPresence] = [:]
    for field in manifest.fields {
      let key = manifest.storageKey(for: field.key)
      // A SECRET IS NOT READ HERE. `string(forKey:)` would materialise the token — and on
      // the legacy Keychain raise an access panel for it — every time this sheet opened,
      // for a value the person has not asked to see. Presence answers what the field needs
      // to draw itself; `revealSecret` does the read, on a click.
      if field.isSecret {
        presence[field.key] = await store.presence(ofSecretKey: key)
        // A reveal that happened before this reload keeps its value: the person is looking
        // at it, and blanking the field under them would read as the token disappearing.
        if loadedSecrets.contains(field.key), let value = values[field.key] {
          loaded[field.key] = value
        }
        continue
      }
      if let value = await store.string(forKey: key) {
        loaded[field.key] = value
      }
    }
    values = loaded
    committed = loaded
    secretPresence = presence
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

  private func commitAll() {
    for field in manifest.fields { commit(field.key) }
  }

  private func save(_ field: FieldDescriptor, _ value: String) async {
    // Refused before it is stored, not after the service has tried to use it.
    //
    // The footnote is already saying why (`ServiceFormLayout.validationFailure`), so this
    // returns quietly rather than raising a second report of the same thing. The draft is
    // left in `values` deliberately: clearing it would throw away what the person typed
    // while telling them to correct it.
    do {
      try await store.set(
        value,
        forKey: manifest.storageKey(for: field.key),
        isSecret: field.isSecret
      )
      committed[field.key] = value
    } catch {
      await model.report(error, while: "save \(field.label)")
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
