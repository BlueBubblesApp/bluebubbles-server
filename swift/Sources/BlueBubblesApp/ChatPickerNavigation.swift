//  ChatPickerNavigation
//  Searching and arrow-keying the conversation picker in the schedule composer.
//
//  `ScheduleComposer.label`, `.choice` and `.addresses` were already `nonisolated static` and
//  are already tested (`ConversationLabelTests`). These two were not: the search filter was a
//  computed property over `@State`, and the arrow-key rule mutated `@State` in place, so
//  neither could be reached from a test and neither had one.
//
//  Both are decisions rather than mechanics. The filter decides that a whitespace-only query
//  is no query; the arrow rule decides that a first press ENTERS the list from the end you
//  pressed towards, and that the ends CLAMP rather than wrap — wrapping from the last result
//  back to the first looks like the list jumped somewhere else.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

enum ChatPickerNavigation {

  /// The rows a query admits.
  ///
  /// Trimmed first, so a query that is only spaces is no query at all rather than one that
  /// matches every label containing a space — which is most of them.
  static func filter(
    _ choices: [ScheduleComposer.ChatChoice], query: String
  ) -> [ScheduleComposer.ChatChoice] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return choices }
    return choices.filter { $0.matches(query) }
  }

  /// Where an arrow key moves the selection, or nil when the press should be ignored.
  ///
  /// Returning the new GUID rather than mutating: the caller owns the `@State`, and a rule
  /// that writes to it cannot be asked what it would do.
  ///
  /// - Parameters:
  ///   - offset: negative for up, positive for down.
  ///   - selected: the current selection, which may be absent or may name a row the current
  ///     query has filtered out.
  static func selection(
    movedBy offset: Int, in choices: [ScheduleComposer.ChatChoice], from selected: String
  ) -> String? {
    guard !choices.isEmpty else { return nil }
    guard let current = choices.firstIndex(where: { $0.guid == selected }) else {
      // Nothing selected yet, or a selection the query has filtered out: down enters at the
      // top, up enters at the bottom, so the first press lands where the eye already is.
      return (offset > 0 ? choices.first : choices.last)?.guid
    }
    // Clamped rather than wrapped. Wrapping from the last result back to the first looks
    // like the list jumped somewhere else.
    return choices[min(max(current + offset, 0), choices.count - 1)].guid
  }
}
