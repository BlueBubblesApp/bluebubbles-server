//  ServiceFormLayout
//  How a service manifest's form is laid out, and which of its fields a person sees.
//
//  A manifest is a flat list of `FormElement`s. Turning that into cards, deciding which
//  fields a `visibleWhen` condition admits, and placing the dividers between them are rules
//  a third-party plugin author will write manifests against — and every one of them lived as
//  a `private func` on `ServiceFormView`, a 697-line file with no test on any line of it.
//  Touching a SwiftUI `View` type from a test process traps, so none of it could be asserted.
//
//  The divider rule is the one worth naming: dividers are AUTOMATIC between two adjacent
//  fields, so a manifest does not have to spell one out between every row, and an explicit
//  divider is honoured but never doubled up with an automatic one or left stranded at the
//  top of a card. Three interacting conditions, and nothing checked any of them.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`: a decision that deserves a test cannot live on
//  the view that uses it.

import BBServiceKit

enum ServiceFormLayout {

  // MARK: - The shapes a form is drawn from

  /// A run of elements under one header, which becomes one card.
  struct Group: Identifiable, Equatable {
    var title: String?
    var elements: [FormElement]
    /// Declared by `.collapsedHeader`. Folded until the user asks for it.
    var isCollapsed: Bool = false

    /// The title, or the first element's identity for the untitled group at the top. A
    /// manifest's headers are unique within it, so this is stable across a redraw where an
    /// index is not.
    var id: String { title ?? elements.first.map(\.identity) ?? "configuration" }
  }

  struct Entry: Identifiable, Equatable {
    var element: FormElement
    /// Set between two adjacent fields, so rows are separated without a manifest having to
    /// spell out a divider between every one of them.
    var needsDivider: Bool

    var id: String { element.identity }
  }

  // MARK: - Grouping

  /// Splits a manifest's elements into cards, one per header.
  ///
  /// Elements before the first header still need a home: a short manifest may have no
  /// headers at all, and dropping its fields would render an empty page.
  static func groups(of elements: [FormElement]) -> [Group] {
    var result: [Group] = []
    var current = Group(title: nil, elements: [])
    for element in elements {
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

  /// The rows of one card: the fields a condition admits, with the dividers placed.
  static func visibleElements(in group: Group, values: [String: String]) -> [Entry] {
    var entries: [Entry] = []
    var previousWasField = false
    for element in group.elements {
      if case .field(let field) = element {
        guard isVisible(field, values: values) else { continue }
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

  /// One line naming what a folded section contains.
  ///
  /// The field labels themselves rather than a fixed phrase, so someone hunting for a
  /// specific control can tell from the outside whether it is in here.
  static func summary(of entries: [Entry]) -> String {
    let labels = entries.compactMap { entry -> String? in
      if case .field(let field) = entry.element { return field.label }
      return nil
    }
    guard !labels.isEmpty else { return "Nothing here needs changing for most setups." }
    return labels.joined(separator: ", ") + "."
  }

  // MARK: - What one field may do

  static func isVisible(_ field: FieldDescriptor, values: [String: String]) -> Bool {
    guard let condition = field.visibleWhen else { return true }
    return condition.isSatisfied(by: values[condition.field] ?? "")
  }

  /// Whether the control needs the row's control column, or has a size of its own.
  ///
  /// A switch is the whole of the second case, and the width it does not use comes off the
  /// field's own explanation beside it. Every other kind here is a field, a picker or a
  /// date control that fills what it is given.
  static func reservesControlColumn(_ field: FieldDescriptor) -> Bool {
    if case .toggle = field.kind { return false }
    return true
  }

  /// Shown, but not editable: because something else now owns the value.
  ///
  /// Deliberately not the same as hiding. A control that disappears reads as a bug; one that
  /// is greyed out with a reason underneath reads as a decision, and answers the question
  /// the user actually has, which is "why can't I change this?".
  static func isDisabled(_ field: FieldDescriptor, values: [String: String]) -> Bool {
    guard let condition = field.disabledWhen else { return false }
    return condition.isSatisfied(by: values[condition.field] ?? "")
  }

  /// Whether a text field holds something the store has not been given.
  ///
  /// Only the text-shaped kinds can: everything else commits the moment it changes.
  static func hasUnsavedEdit(
    _ field: FieldDescriptor, values: [String: String], committed: [String: String]
  ) -> Bool {
    switch field.kind {
    case .text, .url, .number, .decimal, .paragraph:
      return (values[field.key] ?? "") != (committed[field.key] ?? "")
    default:
      return false
    }
  }

  /// The notes under one field.
  ///
  /// A disabled field shows ONE note and nothing else: the reason it cannot be edited is
  /// the only thing worth saying, and stacking "not saved yet" or "required" under a
  /// control nobody can touch is advice about an action that is not available.
  ///
  /// - Parameters:
  ///   - writeError: Why the last write of this field was refused, if it was. Shown only
  ///     while the value in the field is not ITSELF refusable: a draft the form would refuse
  ///     says so, and that sentence is about what is in front of the person now.
  ///   - secret: What an unread secret field says about itself (`SecretFieldPolicy.note`).
  static func footnotes(
    for field: FieldDescriptor, values: [String: String], committed: [String: String],
    writeError: String? = nil, secret: SettingsFootnote? = nil
  ) -> [SettingsFootnote] {
    if isDisabled(field, values: values) {
      return [
        SettingsFootnote(
          text: field.disabledReason ?? "Set elsewhere.",
          kind: .locked,
          symbol: "lock",
          tone: .informational
        )
      ]
    }
    var notes: [SettingsFootnote] = []
    if hasUnsavedEdit(field, values: values, committed: committed) {
      notes.append(
        SettingsFootnote(
          text: "Not saved yet; press Return, or click another field.",
          kind: .unsaved,
          symbol: "pencil.circle",
          tone: .informational
        ))
    }
    if field.isRequired, (values[field.key] ?? "").isEmpty {
      notes.append(
        SettingsFootnote(
          text: "Required.", kind: .required,
          symbol: "exclamationmark.circle", tone: .attention
        ))
    }
    // Answered HERE, under the field, rather than by the service at start-up.
    //
    // zrok's reserved name is the case: an invalid one is refused by zrok, not by the form,
    // so the only report was an alert behind a drawer — and the service retried, so it was
    // 175 refusals in 71 seconds rather than one. A rule the form can check is a rule the
    // person should be told about while the field is in front of them.
    if let reason = validationFailure(field, values: values) ?? writeError {
      notes.append(
        SettingsFootnote(
          text: reason, kind: .error,
          symbol: "exclamationmark.triangle", tone: .problem
        ))
    }
    if let secret {
      notes.append(secret)
    }
    return notes
  }

  /// Why this field's current value would be refused, or nil when it is acceptable.
  ///
  /// Reads the DRAFT (`values`), not what is committed, so the answer moves with the typing
  /// rather than arriving after a save that should not have happened.
  ///
  /// A field nobody can edit right now is not judged: a value inherited from elsewhere, or
  /// greyed out behind another switch, is not this person's to fix, and a complaint about it
  /// under a locked control is noise pointing at nothing.
  static func validationFailure(
    _ field: FieldDescriptor, values: [String: String]
  ) -> String? {
    guard !isDisabled(field, values: values) else { return nil }
    let value = values[field.key] ?? ""
    if let failure = rangeFailure(field, value: value) { return failure }
    return field.validation?.failure(for: value)
  }

  /// Why a number field's value is outside the range its kind declares, or is not a number.
  ///
  /// Refused rather than clamped as it is typed: a field that silently turned 70000 into
  /// 65535 saves a value nobody chose, and a settings row's range is refused by the store
  /// the same way (`Setting.rangeViolation`). An empty field is not judged here;
  /// `isRequired` says whether it may be empty.
  static func rangeFailure(_ field: FieldDescriptor, value: String) -> String? {
    guard !value.isEmpty else { return nil }
    switch field.kind {
    case .number(let range):
      guard let number = Int(value) else { return "Must be a whole number." }
      guard let range, !range.contains(number) else { return nil }
      return "Must be between \(range.lowerBound) and \(range.upperBound)."
    case .decimal(let range):
      guard let number = Double(value) else { return "Must be a number." }
      guard let range, !range.contains(number) else { return nil }
      return "Must be between \(range.lowerBound.formatted()) and "
        + "\(range.upperBound.formatted())."
    default:
      return nil
    }
  }

  /// The chosen options of a multi-select, which is stored as one comma-separated value.
  static func selected(_ field: FieldDescriptor, values: [String: String]) -> Set<String> {
    Set((values[field.key] ?? "").split(separator: ",").map(String.init))
  }
}

extension FormElement {
  /// A stable identity for a row in a rendered form, so a redraw diffs rows rather than
  /// re-creating them by position. Fields are unique by key within a manifest, and the
  /// display elements by their text; a divider has nothing but its neighbours.
  var identity: String {
    switch self {
    case .field(let field): "field:" + field.key
    case .header(let text): "header:" + text
    case .collapsedHeader(let text): "collapsed:" + text
    case .paragraph(let text): "paragraph:" + text
    case .note(let text): "note:" + text
    case .divider: "divider"
    }
  }
}
