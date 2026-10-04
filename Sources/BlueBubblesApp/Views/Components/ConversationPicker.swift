//  ConversationPicker
//  Choosing one conversation, or several, from the list a person recognises.
//
//  The one picker every page uses. It reads `ConversationDirectory`, so every page shows the
//  same row for the same chat: a contact name where the address book has one, the formatted
//  number or the email where it does not, and the address beside the name on a one-to-one
//  chat. The page decides only what the choice is for (`mode`) and holds the result as chat
//  GUIDs, which is what a scheduled message, an export and a webhook filter all store.
//
//  A live-filtered list under a search field rather than a pop-up menu: results are on screen
//  as you type, the newest conversations are there before you type at all, and the field
//  keeps focus while the arrow keys move through the rows. What a click, an arrow and Return
//  do in each mode is `ConversationPicking`'s decision, not this view's.
//
//  The list owns its read and re-reads when the server starts, so a page embedding it has no
//  conversation state of its own to keep in step.

import BBInterfaces
import SwiftUI

struct ConversationPicker: View {

  @Bindable var model: AppModel
  /// The chosen conversations, by GUID. Exactly zero or one in `.single` mode.
  @Binding var selection: Set<String>
  let mode: ConversationSelectionMode
  /// How many rows the list shows before it scrolls.
  var visibleRows: Int = 7

  @State private var conversations: ScreenModel<[ConversationDirectory.Conversation]>
  @State private var search = ""
  @State private var cursor: String?
  @FocusState private var searchIsFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// How many conversations the list holds: the newest, which is what a person picks from.
  /// The search finds within them; a selection outside them is still shown, by GUID.
  static let listLimit = 500

  init(
    model: AppModel, selection: Binding<Set<String>>, mode: ConversationSelectionMode,
    visibleRows: Int = 7
  ) {
    self.model = model
    _selection = selection
    self.mode = mode
    self.visibleRows = visibleRows
    _conversations = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  /// Nil when the message database is not readable, which leaves the list idle rather than
  /// failed: the server is not refusing, it has nothing to answer with yet.
  @MainActor
  private static func read(_ model: AppModel) async throws
    -> [ConversationDirectory.Conversation]?
  {
    guard let interfaces = await model.messaging.interfaces() else { return nil }
    return try await interfaces.conversations.list(limit: listLimit)
  }

  private var all: [ConversationDirectory.Conversation] { conversations.state.value ?? [] }

  private var filtered: [ConversationDirectory.Conversation] {
    ConversationPicking.filter(all, query: search)
  }

  var body: some View {
    let rows = filtered
    VStack(alignment: .leading, spacing: 8) {
      searchField(rows)
      results(rows)
      chosenSummary
    }
    .reloads(conversations, following: model)
    .onAppear { cursor = ConversationPicking.initialCursor(selection: selection, mode: mode) }
  }

  // MARK: - Search

  private func searchField(_ rows: [ConversationDirectory.Conversation]) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("Search conversations", text: $search)
        .textFieldStyle(.plain)
        .focused($searchIsFocused)
        .onSubmit {
          choose(
            ConversationPicking.returnTarget(
              cursor: cursor, in: rows, selection: selection, mode: mode))
        }
        .onKeyPress(.downArrow) { move(by: 1, in: rows) }
        .onKeyPress(.upArrow) { move(by: -1, in: rows) }

      if !search.isEmpty {
        Button {
          search = ""
          searchIsFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  private func move(
    by offset: Int, in rows: [ConversationDirectory.Conversation]
  ) -> KeyPress.Result {
    guard let moved = ConversationPicking.cursor(movedBy: offset, in: rows, from: cursor)
    else { return .ignored }
    cursor = moved
    selection = ConversationPicking.selection(afterMovingTo: moved, from: selection, mode: mode)
    return .handled
  }

  private func choose(_ guid: String?) {
    guard let guid else { return }
    cursor = guid
    selection = ConversationPicking.selecting(guid, in: selection, mode: mode)
  }

  // MARK: - Results

  private static let rowHeight: CGFloat = 30

  private func results(_ rows: [ConversationDirectory.Conversation]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        if rows.isEmpty {
          emptyResults
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(rows) { conversation in
              ConversationPickerRow(
                conversation: conversation,
                isSelected: selection.contains(conversation.id),
                isCursor: mode == .multiple && cursor == conversation.id,
                mode: mode
              ) { choose(conversation.id) }
              .id(conversation.id)
            }
          }
          .padding(2)
        }
      }
      // Sized to the results, so one hit is not a tall box of empty space pushing the rest
      // of the page down.
      .frame(
        height: min(CGFloat(max(rows.count, 1)), CGFloat(visibleRows)) * Self.rowHeight + 4)
      .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
      // Follows an arrow-key move out of view; nil under Reduce Motion, which still scrolls.
      .onChange(of: cursor) { _, guid in
        guard let guid else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
          proxy.scrollTo(guid, anchor: .center)
        }
      }
    }
  }

  @ViewBuilder
  private var emptyResults: some View {
    // Told apart by the read's own state, not by whether the value is empty: a read in
    // flight has no value yet, and "nothing was found" over it would be an answer nobody has
    // established.
    switch conversations.state {
    case .failed(let failure):
      Label(failure, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .idle:
      Label("Waiting for the message database.", systemImage: "clock")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading conversations…")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    case .loaded(let loaded) where loaded.isEmpty:
      Label("No conversations were found on this Mac.", systemImage: "info.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .loaded:
      Label("No conversation matches “\(search)”.", systemImage: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - What is chosen

  /// The selection, kept on screen even when the search has filtered it out, so a form is
  /// never armed against something the person cannot see.
  @ViewBuilder
  private var chosenSummary: some View {
    let chosen = ConversationPicking.chosen(selection, in: all)
    if !selection.isEmpty {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        Text(Self.describe(chosen.known, unknown: chosen.unknown, mode: mode))
          .lineLimit(2)
        Spacer(minLength: 8)
        Button(mode == .single ? "Clear" : "Clear All") {
          selection = []
          cursor = nil
        }
        .buttonStyle(.link)
      }
      .font(.callout)
      .accessibilityElement(children: .combine)
    }
  }

  /// "Weekend Plans", or "3 conversations: Weekend Plans, Alice Example, +1 (555) 555-0102".
  static func describe(
    _ known: [ConversationDirectory.Conversation], unknown: [String],
    mode: ConversationSelectionMode
  ) -> String {
    let names = known.map(\.title) + unknown
    if mode == .single, names.count == 1 { return names[0] }
    return "\(names.count.counted("conversation")): \(names.joined(separator: ", "))"
  }
}

/// One conversation in the list. Its own view for the hover state, so a row's hover is a
/// row-local fact rather than picker state that every keystroke invalidates.
private struct ConversationPickerRow: View {

  let conversation: ConversationDirectory.Conversation
  let isSelected: Bool
  /// Where the arrow keys are, in multiple mode; in single mode the cursor is the selection.
  let isCursor: Bool
  let mode: ConversationSelectionMode
  let choose: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: choose) {
      HStack(spacing: 8) {
        // Always laid out, so names do not shift sideways as the selection moves.
        Image(systemName: symbol)
          .font(mode == .single ? .caption.weight(.bold) : .body)
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .opacity(mode == .single && !isSelected ? 0 : 1)
          .frame(width: 16)
          .accessibilityHidden(true)
        Text(conversation.title)
          .lineLimit(1)
        if let subtitle = conversation.subtitle {
          // Truncates before the title does: the title is what identifies the row.
          Text(subtitle)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(-1)
        }
        Spacer(minLength: 0)
        if conversation.isArchived {
          Tag("archived")
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 30)
      .contentShape(Rectangle())
      .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var symbol: String {
    switch mode {
    case .single: "checkmark"
    case .multiple: isSelected ? "checkmark.square.fill" : "square"
    }
  }

  private var background: AnyShapeStyle {
    if mode == .single, isSelected { return AnyShapeStyle(.tint.opacity(0.18)) }
    if isCursor { return AnyShapeStyle(.tint.opacity(0.12)) }
    if isHovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
    return AnyShapeStyle(.clear)
  }
}
