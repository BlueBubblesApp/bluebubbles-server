//  ServiceFormView
//  A service's configuration, rendered from its manifest.
//
//  The counterpart to `SettingsView`: that screen is generated from settings compiled into the
//  binary, this one from a manifest that may have arrived as JSON. They deliberately look the
//  same to a user — both are built from `SettingsLayout`, so a plugin's configuration is not
//  visibly second-class — but nothing here reads a `Setting<Value>`, because a plugin has none.
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
//  long manifest legible — zrok's twelve elements read as "Account", "Tunnel", "Advanced"
//  instead of one unbroken column — and it costs a manifest author nothing they were not
//  already writing.
//
//  TEXT IS EDITED AS A DRAFT AND COMMITTED ON RETURN OR FOCUS LOSS, exactly as `SettingRow`
//  does, and here the reason is sharper than there. Every proxy service watches its own
//  fields and answers a change with `.restart`, so a form that wrote the store per keystroke
//  restarted the selected tunnel once per character typed into its token field — and each of
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
  /// What the store last accepted, so a commit that changes nothing is skipped — tabbing
  /// through a page must not rewrite every field, and a no-op write of a token would still
  /// restart the tunnel.
  @State private var committed: [String: String] = [:]
  @State private var revealed: Set<String> = []
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
      ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
        // A group whose every field is hidden by `visibleWhen` is dropped entirely
        // rather than left as an empty card, which would read as a rendering fault.
        let visible = visibleElements(in: group)
        if !visible.isEmpty {
          let title = group.title ?? "Configuration"
          SettingsSection(title, trailing: disclosureControl(for: group)) {
            if !group.isCollapsed || expanded.contains(title) {
              ForEach(Array(visible.enumerated()), id: \.offset) { _, entry in
                if entry.needsDivider { SettingsDivider() }
                render(entry.element)
              }
            } else {
              // The card stays, holding one line that says what is inside it.
              // Collapsing the header away entirely would leave the user with no
              // sign that there is anything here to open.
              Text(summary(of: visible))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
    // on the floor — the one outcome worse than saving too eagerly.
    .onDisappear { commitAll() }
  }

  // MARK: - Grouping

  /// A run of elements under one header, which becomes one card.
  private struct Group {
    var title: String?
    var elements: [FormElement]
    /// Declared by `.collapsedHeader`. Folded until the user asks for it.
    var isCollapsed: Bool = false
  }

  private struct Entry {
    var element: FormElement
    /// Set between two adjacent fields, so rows are separated without a manifest having to
    /// spell out a divider between every one of them.
    var needsDivider: Bool
  }

  private var groups: [Group] {
    var result: [Group] = []
    // Elements before the first header still need a home — a short manifest may have no
    // headers at all, and dropping its fields would render an empty page.
    var current = Group(title: nil, elements: [])
    for element in manifest.settings {
      switch element {
      case .header(let text):
        if !current.elements.isEmpty { result.append(current) }
        current = Group(title: text, elements: [])
      case .collapsedHeader(let text):
        if !current.elements.isEmpty { result.append(current) }
        current = Group(title: text, elements: [], isCollapsed: true)
      default:
        current.elements.append(element)
      }
    }
    if !current.elements.isEmpty { result.append(current) }
    return result
  }

  /// The show/hide button on a collapsed section's header, and nothing at all on any other.
  private func disclosureControl(for group: Group) -> AnyView? {
    guard group.isCollapsed, let title = group.title else { return nil }
    let isOpen = expanded.contains(title)
    return AnyView(
      Button {
        if isOpen { expanded.remove(title) } else { expanded.insert(title) }
      } label: {
        Label(isOpen ? "Hide" : "Show", systemImage: isOpen ? "chevron.up" : "chevron.down")
          .labelStyle(.titleAndIcon)
          .font(.callout)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(isOpen ? "Hide \(title)" : "Show \(title)")
    )
  }

  /// One line naming what a folded section contains.
  ///
  /// The field labels themselves rather than a fixed phrase, so someone hunting for a
  /// specific control can tell from the outside whether it is in here.
  private func summary(of entries: [Entry]) -> String {
    let labels = entries.compactMap { entry -> String? in
      if case .field(let field) = entry.element { return field.label }
      return nil
    }
    guard !labels.isEmpty else { return "Nothing here needs changing for most setups." }
    return labels.joined(separator: ", ") + "."
  }

  private func visibleElements(in group: Group) -> [Entry] {
    var entries: [Entry] = []
    var previousWasField = false
    for element in group.elements {
      if case .field(let field) = element {
        guard isVisible(field) else { continue }
        entries.append(Entry(element: element, needsDivider: previousWasField))
        previousWasField = true
      } else {
        // An explicit divider is honoured, but never doubled up with an automatic one.
        if case .divider = element, entries.isEmpty { continue }
        entries.append(Entry(element: element, needsDivider: false))
        previousWasField = false
      }
    }
    return entries
  }

  // MARK: - Elements

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
        // No Return to commit here — Return is a newline in a text editor — so focus loss
        // and leaving the page are the commit points.
        TextEditor(text: draft(field))
          .frame(minHeight: 96)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
          .focused($editing, equals: field.key)
        ForEach(Array(footnotes(for: field).enumerated()), id: \.offset) { _, note in note }
      }

    case .multiSelect(let options):
      SettingsWideRow(title: field.label, help: field.help) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(options, id: \.value) { option in
            Toggle(option.label, isOn: multiBinding(field, option: option.value))
              .toggleStyle(.checkbox)
          }
        }
        ForEach(Array(footnotes(for: field).enumerated()), id: \.offset) { _, note in note }
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
          .disabled(isDisabled(field))
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
    if isDisabled(field) {
      return [
        SettingsFootnote(
          text: field.disabledReason ?? "Set elsewhere.",
          symbol: "lock",
          tone: .neutral
        )
      ]
    }
    var notes: [SettingsFootnote] = []
    if hasUnsavedEdit(field) {
      notes.append(
        SettingsFootnote(
          text: "Not saved yet — press Return, or click another field.",
          symbol: "pencil.circle",
          tone: .neutral
        ))
    }
    if field.isRequired, (values[field.key] ?? "").isEmpty {
      notes.append(
        SettingsFootnote(
          text: "Required.", symbol: "exclamationmark.circle", tone: .warning
        ))
    }
    return notes
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
          SecureField(placeholder ?? "", text: draft(field))
        } else {
          TextField(placeholder ?? "", text: draft(field))
        }
      }
      .textFieldStyle(.roundedBorder)
      .controlSize(.large)
      .focused($editing, equals: field.key)
      .onSubmit { commit(field.key) }

      if field.isSecret {
        // Revealable, because a user pasting a token needs to be able to check it —
        // and a write-only field they cannot verify is where "it says it's saved but
        // it does not work" comes from.
        Button {
          if revealed.contains(field.key) {
            revealed.remove(field.key)
          } else {
            revealed.insert(field.key)
          }
        } label: {
          Image(systemName: revealed.contains(field.key) ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(revealed.contains(field.key) ? "Hide" : "Reveal")
      }
    }
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
      get: { selected(field).contains(option) },
      set: { isOn in
        var current = selected(field)
        if isOn { current.insert(option) } else { current.remove(option) }
        values[field.key] = current.sorted().joined(separator: ",")
        commit(field.key)
      }
    )
  }

  private func selected(_ field: FieldDescriptor) -> Set<String> {
    Set((values[field.key] ?? "").split(separator: ",").map(String.init))
  }

  private func isVisible(_ field: FieldDescriptor) -> Bool {
    guard let condition = field.visibleWhen else { return true }
    return condition.isSatisfied(by: values[condition.field] ?? "")
  }

  /// Shown, but not editable — because something else now owns the value.
  ///
  /// Deliberately not the same as hiding. A control that disappears reads as a bug; one
  /// that is greyed out with a reason underneath reads as a decision, and answers the
  /// question the user actually has, which is "why can't I change this?".
  private func isDisabled(_ field: FieldDescriptor) -> Bool {
    guard let condition = field.disabledWhen else { return false }
    return condition.isSatisfied(by: values[condition.field] ?? "")
  }

  /// Whether a text field holds something the store has not been given.
  ///
  /// Only the text-shaped kinds can: everything else commits the moment it changes.
  private func hasUnsavedEdit(_ field: FieldDescriptor) -> Bool {
    switch field.kind {
    case .text, .url, .number, .decimal, .paragraph:
      return (values[field.key] ?? "") != (committed[field.key] ?? "")
    default:
      return false
    }
  }

  private func load() async {
    var loaded: [String: String] = [:]
    for field in manifest.fields {
      if let value = await store.string(forKey: manifest.storageKey(for: field.key)) {
        loaded[field.key] = value
      }
    }
    values = loaded
    committed = loaded
  }

  // MARK: - Committing

  /// Writes one field's draft to the store, if it actually differs from what is stored.
  ///
  /// The equality check is what makes commit-on-blur quiet — and, for this form, what keeps a
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
