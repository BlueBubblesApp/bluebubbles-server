//  PausedSearchField
//  A `SearchField` over a `SearchDraft`: the table is searched once typing pauses, on Return,
//  and at once when the field is cleared.
//
//  For a page whose search is a database read; see `SearchDraft` for what a read per
//  keystroke cost. A field that filters something already in memory is a plain
//  `SearchField`.

import SwiftUI

struct PausedSearchField: View {

  let prompt: String
  @Binding var search: SearchDraft

  init(_ prompt: String, search: Binding<SearchDraft>) {
    self.prompt = prompt
    self._search = search
  }

  var body: some View {
    // Clearing is not typing, so it searches at once rather than after the pause.
    SearchField(prompt, text: $search.text, onClear: { search.clear() })
      // Return searches now rather than after the pause.
      .onSubmit { search.commit() }
      // A new keystroke cancels this and starts the wait again, so only a pause searches.
      .task(id: search.text) {
        guard (try? await Task.sleep(for: SearchDraft.settle)) != nil else { return }
        search.commit()
      }
  }
}
