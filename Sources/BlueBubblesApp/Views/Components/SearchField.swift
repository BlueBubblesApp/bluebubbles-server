//  SearchField
//  A search box on a page, beside the list it narrows.
//
//  Three pages drew this (Contacts, the Audit Log and the conversation picker in the schedule
//  sheet) on three different backgrounds: a grey of its own, and glass at two paddings. It is
//  one control, so it has one look: the glass surface every other piece of control chrome
//  uses, which is what two of the three had already chosen.
//
//  NOT `.searchable`. A field on the page sits with the list it filters and beside the count it
//  changes, rather than in window chrome shared with navigation that has nothing to do with
//  that list.
//
//  What a page adds stays on the page: `.onSubmit` reaches the field from outside, because it
//  applies to the text fields beneath it. Width is the caller's too: narrow beside a table,
//  full width in a sheet. The arrow keys are the exception and are an argument (`onMove`),
//  because they have to be bound on the text field ITSELF: it is what holds focus, and the
//  field editor behind it has a use of its own for up and down.

import SwiftUI

struct SearchField: View {

  /// Names the field, for VoiceOver and as its placeholder: "Search contacts".
  let prompt: String
  @Binding var text: String
  /// Takes focus when the field appears, for a sheet whose first question this is.
  var focusesOnAppear = false
  /// What the clear button does. Nil empties `text`; a page whose search waits for typing to
  /// pause passes its own, because clearing is not typing and should not wait.
  var onClear: (() -> Void)?
  /// Moves a selection in the results below by the offset (+1 for down, -1 for up) without
  /// leaving the field. Nil leaves the arrow keys to the field.
  var onMove: ((Int) -> KeyPress.Result)?

  @FocusState private var isFocused: Bool

  init(
    _ prompt: String, text: Binding<String>, focusesOnAppear: Bool = false,
    onMove: ((Int) -> KeyPress.Result)? = nil, onClear: (() -> Void)? = nil
  ) {
    self.prompt = prompt
    self._text = text
    self.focusesOnAppear = focusesOnAppear
    self.onMove = onMove
    self.onClear = onClear
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        // The field beside it is named, so this would be read out twice.
        .accessibilityHidden(true)

      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onKeyPress(.downArrow) { onMove?(1) ?? .ignored }
        .onKeyPress(.upArrow) { onMove?(-1) ?? .ignored }
        .accessibilityLabel(prompt)

      // Only once there is something to clear. A permanently visible clear button on an
      // empty field invites a click that does nothing.
      if !text.isEmpty {
        Button {
          if let onClear { onClear() } else { text = "" }
          // Back in the field: someone who clears a search is about to type another.
          isFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .glassSurface(cornerRadius: SettingsMetrics.fieldCornerRadius)
    .task {
      guard focusesOnAppear else { return }
      isFocused = true
    }
  }
}
