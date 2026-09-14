//  ServiceFormLayoutTests
//  How a manifest's flat element list becomes the form a person sees.
//
//  These rules were `private func`s on `ServiceFormView`, 697 lines with no test on any of
//  them, and they are the rules a third-party manifest author writes against: which fields a
//  `visibleWhen` admits, where the dividers land, what a folded card says about itself.
//  Touching a SwiftUI `View` type from a test process traps, so none of it could be asserted
//  until it moved to `ServiceFormLayout`.

import BBBuiltIns
import BBServiceKit
import Testing

@testable import BlueBubblesApp

/// `@MainActor` because `SettingsFootnote` is a `View`, so its stored properties carry that
/// isolation. The layout rules themselves are pure.
@Suite("Service form layout")
@MainActor
struct ServiceFormLayoutTests {

  private func field(
    _ key: String,
    label: String? = nil,
    kind: FieldKind = .text(),
    visibleWhen: FieldCondition? = nil,
    disabledWhen: FieldCondition? = nil
  ) -> FormElement {
    .field(
      FieldDescriptor(
        key: key, label: label ?? key.capitalized, kind: kind,
        visibleWhen: visibleWhen, disabledWhen: disabledWhen))
  }

  private func descriptor(
    _ key: String,
    kind: FieldKind = .text(),
    visibleWhen: FieldCondition? = nil,
    disabledWhen: FieldCondition? = nil
  ) -> FieldDescriptor {
    FieldDescriptor(
      key: key, label: key.capitalized, kind: kind,
      visibleWhen: visibleWhen, disabledWhen: disabledWhen)
  }

  // MARK: - Validation

  private var zrokName: FieldDescriptor {
    FieldDescriptor(
      key: "reserved_name", label: "Reserved Name", kind: .text(),
      disabledWhen: FieldCondition(field: "locked", equals: "true"),
      validation: FieldValidation(
        pattern: "[a-z0-9]{4,32}", message: "lowercase letters and digits, 4 to 32."))
  }

  /// REGRESSION. The form stored a name zrok refuses, and the only report was an alert.
  @Test("An invalid draft is called out under the field")
  func invalidDraftGetsANote() {
    let notes = ServiceFormLayout.footnotes(
      for: zrokName, values: ["reserved_name": "bb-test"], committed: [:])
    #expect(notes.contains { $0.kind == .error })
    #expect(
      ServiceFormLayout.validationFailure(zrokName, values: ["reserved_name": "bb-test"])
        != nil)
  }

  @Test("A valid draft gets no complaint, and neither does an empty one")
  func validDraftIsQuiet() {
    for value in ["bbtest", ""] {
      let notes = ServiceFormLayout.footnotes(
        for: zrokName, values: ["reserved_name": value], committed: [:])
      #expect(!notes.contains { $0.kind == .error }, "complained about \(value)")
    }
  }

  /// A field the person cannot edit right now is not theirs to fix, so a complaint under a
  /// locked control would point at a control that does nothing.
  @Test("A disabled field is not judged")
  func disabledFieldsAreNotJudged() {
    let values = ["reserved_name": "bb-test", "locked": "true"]
    #expect(ServiceFormLayout.validationFailure(zrokName, values: values) == nil)
    let notes = ServiceFormLayout.footnotes(for: zrokName, values: values, committed: [:])
    #expect(!notes.contains { $0.kind == .error })
  }

  /// A field with no rule behaves exactly as it did.
  @Test("A field that declares no validation is never refused")
  func unvalidatedFieldsAreUnaffected() {
    #expect(ServiceFormLayout.validationFailure(descriptor("anything"), values: [:]) == nil)
    #expect(
      ServiceFormLayout.validationFailure(
        descriptor("anything"), values: ["anything": "!!! whatever !!!"]) == nil)
  }

  /// The shipped manifest carries zrok's rule, and its own placeholder obeys it. The
  /// placeholder used to be `my-server`, an example of a name zrok rejects, in the field
  /// whose rule it was demonstrating.
  @Test("zrok's reserved name declares its rule, and the placeholder satisfies it")
  func zrokManifestCarriesTheRule() throws {
    let field = try #require(
      BuiltInManifests.zrok.fields.first { $0.key == "reserved_name" })
    let validation = try #require(field.validation, "zrok's name rule is not declared")
    #expect(validation.failure(for: "bb-test") != nil)
    guard case .text(let placeholder) = field.kind else {
      Issue.record("the reserved name is no longer a text field")
      return
    }
    let example = try #require(placeholder)
    #expect(
      validation.failure(for: example) == nil,
      "the placeholder \(example) is a name zrok would refuse")
  }

  // MARK: - Grouping

  /// A manifest with no headers at all still renders. Its fields used to have nowhere to go.
  @Test("Elements before the first header still get a card")
  func untitledLeadingGroup() {
    let groups = ServiceFormLayout.groups(of: [field("a"), field("b")])
    #expect(groups.count == 1)
    #expect(groups[0].title == nil)
    #expect(groups[0].elements.count == 2)
  }

  @Test("Each header starts a new card, and a collapsed header says so")
  func headersSplitGroups() {
    let groups = ServiceFormLayout.groups(of: [
      field("a"),
      .header("Connection"), field("b"), field("c"),
      .collapsedHeader("Advanced"), field("d"),
    ])
    #expect(groups.map(\.title) == [nil, "Connection", "Advanced"])
    #expect(groups.map(\.isCollapsed) == [false, false, true])
    #expect(groups.map { $0.elements.count } == [1, 2, 1])
  }

  /// A header with nothing under it produces no card, so a manifest that ends on one — or
  /// puts two in a row — does not render an empty box.
  @Test("A header with no elements under it produces no card")
  func emptyHeaderIsDropped() {
    let groups = ServiceFormLayout.groups(of: [
      .header("Empty"), .header("Also empty"), field("a"), .header("Trailing"),
    ])
    #expect(groups.map(\.title) == ["Also empty"])
  }

  @Test("A group's id is stable across a redraw")
  func groupIdentity() {
    let titled = ServiceFormLayout.Group(title: "Connection", elements: [field("a")])
    #expect(titled.id == "Connection")
    let untitled = ServiceFormLayout.Group(title: nil, elements: [field("port")])
    #expect(untitled.id == "field:port")
    let empty = ServiceFormLayout.Group(title: nil, elements: [])
    #expect(empty.id == "configuration")
  }

  // MARK: - Dividers
  //
  // Three interacting rules, and nothing checked any of them before.

  @Test("A divider is placed automatically between two adjacent fields, never before the first")
  func automaticDividers() {
    let group = ServiceFormLayout.Group(
      title: nil, elements: [field("a"), field("b"), field("c")])
    let entries = ServiceFormLayout.visibleElements(in: group, values: [:])
    #expect(entries.map(\.needsDivider) == [false, true, true])
  }

  @Test("A non-field between two fields breaks the run, so no divider is added after it")
  func paragraphBreaksTheRun() {
    let group = ServiceFormLayout.Group(
      title: nil, elements: [field("a"), .paragraph("Explanation"), field("b")])
    let entries = ServiceFormLayout.visibleElements(in: group, values: [:])
    #expect(entries.map(\.needsDivider) == [false, false, false])
  }

  /// An explicit divider is honoured, but never left stranded at the top of a card — which
  /// is what a manifest that opens with one, or whose leading fields are all hidden, would
  /// otherwise produce.
  @Test("A leading explicit divider is dropped, and a later one is kept")
  func explicitDividers() {
    let leading = ServiceFormLayout.Group(title: nil, elements: [.divider, field("a")])
    #expect(ServiceFormLayout.visibleElements(in: leading, values: [:]).count == 1)

    let middle = ServiceFormLayout.Group(
      title: nil, elements: [field("a"), .divider, field("b")])
    let entries = ServiceFormLayout.visibleElements(in: middle, values: [:])
    #expect(entries.count == 3)
    // The explicit one is not doubled up with an automatic one on the field after it.
    #expect(entries.map(\.needsDivider) == [false, false, false])
  }

  /// The interaction the divider rules exist for: a hidden leading field must not leave the
  /// divider that followed it stranded at the top of the card.
  @Test("A divider left leading by a hidden field is dropped too")
  func dividerStrandedByAHiddenField() {
    let group = ServiceFormLayout.Group(
      title: nil,
      elements: [
        field("secret", visibleWhen: FieldCondition(field: "mode", equals: "advanced")),
        .divider,
        field("always"),
      ])
    let entries = ServiceFormLayout.visibleElements(in: group, values: ["mode": "simple"])
    #expect(entries.map(\.id) == ["field:always"])
  }

  // MARK: - Visibility

  @Test("A field with no condition is always visible")
  func unconditionalField() {
    #expect(ServiceFormLayout.isVisible(descriptor("a"), values: [:]))
  }

  @Test("A condition is satisfied by its value or any of its alternatives")
  func conditionAlternatives() {
    let condition = FieldCondition(field: "mode", equals: "token", orEquals: ["config"])
    let hostname = descriptor("hostname", visibleWhen: condition)
    #expect(ServiceFormLayout.isVisible(hostname, values: ["mode": "token"]))
    #expect(ServiceFormLayout.isVisible(hostname, values: ["mode": "config"]))
    #expect(!ServiceFormLayout.isVisible(hostname, values: ["mode": "quick"]))
    // An unset controlling field reads as empty, which satisfies nothing here.
    #expect(!ServiceFormLayout.isVisible(hostname, values: [:]))
  }

  /// Hiding and greying out are separate decisions, and a field can be both, or neither.
  @Test("Disabled is not visible, and is false by default")
  func disabling() {
    #expect(!ServiceFormLayout.isDisabled(descriptor("a"), values: [:]))
    let owned = descriptor(
      "port", disabledWhen: FieldCondition(field: "managed", equals: "true"))
    #expect(ServiceFormLayout.isDisabled(owned, values: ["managed": "true"]))
    #expect(!ServiceFormLayout.isDisabled(owned, values: ["managed": "false"]))
    // Still visible: a control that disappears reads as a bug, one greyed out reads as a
    // decision.
    #expect(ServiceFormLayout.isVisible(owned, values: ["managed": "true"]))
  }

  // MARK: - Unsaved edits

  /// Only the text-shaped kinds can hold an uncommitted value; everything else commits the
  /// moment it changes, so reporting one as unsaved would put a permanent marker on a toggle.
  @Test("Only text-shaped fields can hold an unsaved edit")
  func unsavedEditKinds() {
    let values = ["k": "new"]
    let committed = ["k": "old"]
    for kind: FieldKind in [.text(), .url, .number(), .decimal(), .paragraph] {
      #expect(
        ServiceFormLayout.hasUnsavedEdit(
          descriptor("k", kind: kind), values: values, committed: committed),
        "\(kind) should be able to hold an unsaved edit")
    }
    for kind: FieldKind in [.toggle(), .date, .select(options: [])] {
      #expect(
        !ServiceFormLayout.hasUnsavedEdit(
          descriptor("k", kind: kind), values: values, committed: committed),
        "\(kind) commits on change and is never unsaved")
    }
  }

  @Test("A value equal to the committed one is not an unsaved edit")
  func noEditIsNoEdit() {
    #expect(
      !ServiceFormLayout.hasUnsavedEdit(
        descriptor("k"), values: ["k": "same"], committed: ["k": "same"]))
    // Absent on both sides reads as equal, not as an edit of "" over nothing.
    #expect(!ServiceFormLayout.hasUnsavedEdit(descriptor("k"), values: [:], committed: [:]))
  }

  // MARK: - Multi-select

  @Test("A multi-select is stored comma-separated and read back as a set")
  func multiSelect() {
    #expect(
      ServiceFormLayout.selected(descriptor("k"), values: ["k": "a,b,c"]) == ["a", "b", "c"])
    #expect(ServiceFormLayout.selected(descriptor("k"), values: ["k": ""]).isEmpty)
    #expect(ServiceFormLayout.selected(descriptor("k"), values: [:]).isEmpty)
  }

  // MARK: - Footnotes

  /// A disabled field shows ONE note and nothing else. Stacking "not saved yet" or
  /// "required" under a control nobody can touch is advice about an action that is not
  /// available — and both of those conditions can be true at the same time as the lock.
  @Test("A disabled field shows only the reason it is disabled")
  func disabledShowsOneNote() {
    let field = FieldDescriptor(
      key: "port", label: "Port", kind: .text(), isRequired: true,
      disabledWhen: FieldCondition(field: "managed", equals: "true"),
      disabledReason: "Managed by the tunnel.")
    let notes = ServiceFormLayout.footnotes(
      for: field, values: ["managed": "true", "port": ""], committed: ["port": "8080"])
    #expect(notes.count == 1)
    #expect(notes.first?.kind == .locked)
    #expect(notes.first?.text == "Managed by the tunnel.")
  }

  @Test("A disabled field with no stated reason still says something")
  func disabledWithoutAReason() {
    let field = FieldDescriptor(
      key: "port", label: "Port", kind: .text(),
      disabledWhen: FieldCondition(field: "managed", equals: "true"))
    let notes = ServiceFormLayout.footnotes(
      for: field, values: ["managed": "true"], committed: [:])
    #expect(notes.first?.text == "Set elsewhere.")
  }

  @Test("A required field left empty says so")
  func requiredAndEmpty() {
    let field = FieldDescriptor(
      key: "token", label: "Token", kind: .text(), isRequired: true)
    #expect(
      ServiceFormLayout.footnotes(for: field, values: [:], committed: [:])
        .contains { $0.kind == .required })
    #expect(
      !ServiceFormLayout.footnotes(
        for: field, values: ["token": "abc"], committed: ["token": "abc"]
      ).contains { $0.kind == .required })
  }

  @Test("An uncommitted edit and a required-but-empty field can both be said at once")
  func unsavedAndRequired() {
    let field = FieldDescriptor(
      key: "token", label: "Token", kind: .text(), isRequired: true)
    let notes = ServiceFormLayout.footnotes(
      for: field, values: ["token": ""], committed: ["token": "was-set"])
    #expect(notes.map(\.kind) == [.unsaved, .required])
  }

  @Test("A settled optional field says nothing")
  func quietField() {
    let field = FieldDescriptor(key: "note", label: "Note", kind: .text())
    #expect(
      ServiceFormLayout.footnotes(
        for: field, values: ["note": "x"], committed: ["note": "x"]
      ).isEmpty)
  }

  // MARK: - The folded summary

  @Test("A folded card names the fields inside it")
  func summaryNamesFields() {
    let group = ServiceFormLayout.Group(
      title: "Advanced",
      elements: [field("a", label: "Port"), .paragraph("noise"), field("b", label: "Host")])
    let entries = ServiceFormLayout.visibleElements(in: group, values: [:])
    #expect(ServiceFormLayout.summary(of: entries) == "Port, Host.")
  }

  /// A card whose fields are all hidden by their conditions still needs a sentence, or the
  /// header sits above nothing with no explanation.
  @Test("A card with no visible fields says so rather than showing an empty list")
  func summaryWithNoFields() {
    let group = ServiceFormLayout.Group(title: "Advanced", elements: [.paragraph("only prose")])
    let entries = ServiceFormLayout.visibleElements(in: group, values: [:])
    #expect(
      ServiceFormLayout.summary(of: entries) == "Nothing here needs changing for most setups.")
  }
}
