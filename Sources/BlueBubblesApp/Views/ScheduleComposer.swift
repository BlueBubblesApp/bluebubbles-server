//  ScheduleComposer
//  Creating a scheduled message.
//
//  The recipient is chosen from EXISTING chats rather than typed as a GUID. A chat GUID is
//  `iMessage;-;+15550101234` and getting the service prefix wrong produces a message that
//  fails at send time, hours later, with the user long gone. Picking from chats that already
//  exist means the GUID is never assembled by hand.
//
//  There is still an escape hatch for an address with no chat yet, because refusing that case
//  would make the composer unable to do something the API can. It says plainly what it will
//  build, so a failure is at least predictable.
//
//  Conversations are labelled with contact names where the address book has them. This is a
//  best-effort layer over the same list: an address with no contact (including every address
//  on a server that was never granted contact access) keeps the formatted number it has
//  always shown, so the screen degrades to exactly what it was rather than to something worse.
//  A one-to-one conversation shows the address after the name, in secondary colour, because a
//  name is the friendly answer and the address is the true one.
//
//  The conversation is chosen from a LIVE-FILTERED LIST rather than a search box feeding a
//  pop-up menu. The menu version made you type, then open a separate control to find out what
//  you had typed: the results were hidden behind a click, so the search box could not tell
//  you it had narrowed to one thing, or to nothing. Results are on screen as you type, the
//  most recent conversations are there before you type at all, and arrow keys move through
//  them without leaving the field.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBInterfaces
import BBSerialization
import BlueBubblesServerCore
import SwiftUI

struct ScheduleComposer: View {

  @Bindable var model: AppModel
  let onDone: () -> Void

  /// The conversation list, through the shared screen state.
  ///
  /// Not `(try? await …) ?? []`: a server that REFUSED and a Mac with no conversations must
  /// not arrive at the picker as the same empty array, or `emptyResults` below cannot tell
  /// them apart.
  ///
  /// Only the conversations are behind this. The contact names are resolved in a second
  /// pass on purpose (see `loadChats`), and folding both into one snapshot would make the
  /// list wait for the lookup it was deliberately allowed to render without.
  @State private var conversations: ScreenModel<[ChatInterface.ChatSummary]>

  init(model: AppModel, onDone: @escaping () -> Void) {
    self.model = model
    self.onDone = onDone
    _conversations = State(initialValue: ScreenModel { try await Self.readChats(model) })
  }

  /// Nil when the message database is not readable, which leaves the screen idle rather
  /// than failed: the server is not refusing, it has nothing to answer with yet.
  @MainActor
  private static func readChats(_ model: AppModel) async throws -> [ChatInterface.ChatSummary]? {
    guard let interfaces = await model.messaging.interfaces() else { return nil }
    return try await interfaces.chat.summaries(limit: 500)
  }

  @Environment(\.dismiss) private var dismiss

  /// What the form holds, and what Save sends: `ScheduleDraft`, which decides whether the
  /// form is complete and what the request carries, off the view so it can be asserted.
  @State private var draft = ScheduleDraft()
  private var chats: [ChatInterface.ChatSummary] { conversations.state.value ?? [] }
  /// Address -> contact name, for the addresses these chats are with. Empty when contact
  /// access was never granted, or when nobody in the list is in the address book.
  @State private var contactNames: [String: String] = [:]
  @State private var chatSearch = ""
  @State private var isSaving = false
  @State private var error: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    SheetScaffold(
      title: "Schedule a Message",
      subtitle: "It is stored on the server and sent even if this window is closed.",
      confirmTitle: "Schedule",
      isConfirmEnabled: draft.canSave && !isSaving,
      error: error,
      confirm: { await save() }
    ) {
      recipientSection
      messageSection
      timingSection
    }
    .task { await loadChats() }
  }

  // MARK: - Sections

  private var recipientSection: some View {
    SettingsSection("Send to") {
      SettingsRow(title: "Recipient") {
        Picker("", selection: $draft.recipient) {
          ForEach(ScheduleDraft.Recipient.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      SettingsDivider()

      if draft.recipient == .existingChat {
        SettingsWideRow(
          title: "Conversation",
          help: "Only conversations that already exist. Start a new one in Messages "
            + "first, or send to an address below."
        ) {
          // Filtered ONCE per render and handed to the pieces that need it, rather than
          // recomputed by each of them.
          let filtered = filteredChats
          searchField
          resultsList(filtered)
          selectionSummary
        }
      } else {
        SettingsRow(title: "Address", help: "A phone number or email address.") {
          TextField("+15550101234", text: $draft.address)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
        }
        SettingsDivider()
        SettingsRow(title: "Service") {
          Picker("", selection: $draft.service) {
            Text("iMessage").tag("iMessage")
            Text("SMS").tag("SMS")
          }
          .labelsHidden()
          .controlSize(.large)
          .frame(maxWidth: 200)
        }
        if draft.hasAddress {
          SettingsDivider()
          // Shown rather than assembled invisibly: if this is wrong, it fails at
          // send time and the user is not there to see it.
          SettingsRow(title: "Will send to") {
            Text(draft.composedGUID)
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var messageSection: some View {
    SettingsSection("Message") {
      SettingsWideRow(title: "Text") {
        TextEditor(text: $draft.message)
          .font(.body)
          .frame(minHeight: 110)
          .scrollContentBackground(.hidden)
          .padding(6)
          .glassSurface(cornerRadius: SettingsMetrics.fieldCornerRadius)
      }
    }
  }

  private var timingSection: some View {
    SettingsSection("When") {
      SettingsRow(
        title: "Send at",
        help: "Must be in the future; the server rejects a past time rather than "
          + "sending immediately."
      ) {
        // Bounded at now, so a past time cannot be chosen at all. The server refuses one,
        // and finding that out when the Schedule button reports it is finding out late.
        DatePicker(
          "", selection: $draft.sendAt, in: Date()...,
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .controlSize(.large)
      }

      SettingsDivider()

      SettingsRow(title: "Repeat") {
        Picker("", selection: $draft.repeats) {
          ForEach(ScheduleRecurrence.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 200)
      }

      if draft.repeats != .never {
        SettingsDivider()
        SettingsRow(
          title: "Every",
          help: "How many \(draft.repeats.period.map { $0 + "s" } ?? "periods") between sends."
        ) {
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            // Clamped as typed, by the draft: see `ScheduleDraft.every`.
            TextField("", value: $draft.every, format: .number)
              .textFieldStyle(.roundedBorder)
              .controlSize(.large)
              .frame(width: 90)
            Stepper("", value: $draft.every, in: ScheduleDraft.intervalRange).labelsHidden()
          }
        }
        SettingsDivider()
        // Calendar months and years, and the one edge that has: a date not every month
        // has. Said where the interval is chosen, so the 31st is picked knowing what
        // February does with it.
        SettingsFootnote(text: draft.repeats.note, symbol: "info.circle")
          .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Choosing a conversation

  /// The app's one search box, with the arrow keys moving through the results under it.
  ///
  /// The arrow keys are bound on the FIELD rather than on the list because the field is what
  /// holds focus: the whole point of the rewrite is that the list never takes focus away from
  /// typing, so a key handler on the list would only fire once someone had already clicked
  /// into it. Focused on open, because this is the first thing the sheet asks for and typing
  /// is how it gets answered; clearing puts focus back in it.
  private var searchField: some View {
    SearchField(
      "Search conversations", text: $chatSearch, focusesOnAppear: true,
      onMove: moveSelection(by:)
    )
    .onSubmit {
      // Return takes the top hit when nothing is chosen yet. It is otherwise
      // the sheet's default action, which is what someone finishing the form
      // expects it to be.
      if draft.selectedChatGUID.isEmpty, let first = filteredChats.first {
        draft.selectedChatGUID = first.guid
      }
    }
  }

  private func resultsList(_ filtered: [ConversationChoice]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        if filtered.isEmpty {
          emptyResults
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(filtered) { choice in
              ConversationRow(
                label: choice.label,
                isSelected: choice.guid == draft.selectedChatGUID
              ) { draft.selectedChatGUID = choice.guid }
              .id(choice.guid)
            }
          }
          .padding(ConversationRow.inset)
        }
      }
      .frame(height: resultsHeight(filtered))
      .glassSurface(cornerRadius: SettingsMetrics.fieldCornerRadius)
      // Follows an arrow-key move out of view. Without this, holding the down arrow
      // walks the selection past the bottom of a box that never scrolls.
      .onChange(of: draft.selectedChatGUID) { _, guid in
        guard !guid.isEmpty else { return }
        // Nil under Reduce Motion, which still scrolls: it just arrives rather than
        // travels. Same rule the floating bar follows.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
          proxy.scrollTo(guid, anchor: .center)
        }
      }
    }
  }

  /// Sized to the results, up to six rows.
  ///
  /// A fixed-height box would be mostly empty space on a search that narrowed to one hit,
  /// and this sheet has two more sections under it that a tall empty box pushes off screen.
  private func resultsHeight(_ filtered: [ConversationChoice]) -> CGFloat {
    let rows = max(filtered.count, 1)
    return min(CGFloat(rows) * Self.rowHeight, CGFloat(6) * Self.rowHeight) + 4
  }

  private static let rowHeight: CGFloat = 26

  @ViewBuilder
  private var emptyResults: some View {
    // FIVE situations, told apart by switching on the read's own state rather than by
    // asking whether the value is empty.
    //
    // This said it told three apart and told two: it read `state.value`, which is nil
    // until the first result lands, so a read in flight was indistinguishable from a read
    // that came back with nothing. Opening this sheet on a Mac with hundreds of
    // conversations announced "No conversations were found" until the read returned, and
    // the sentence hedged with "the server may still be reading the message database"
    // precisely because it could not tell which it was looking at.
    //
    // `ScreenState` keeps `idle` and `loading` apart for exactly this reason and says so
    // in its own comment. The states were there; this view was throwing them away.
    switch conversations.state {
    case .failed(let failure):
      Label(failure, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)

    case .idle:
      // The read returned nil, which `ScreenModel` treats as "not available yet" rather
      // than a failure: there is no message database to ask. Nothing is wrong here, so
      // this must not read as an error.
      Label("Waiting for the message database.", systemImage: "clock")
        .font(.callout)
        .foregroundStyle(.secondary)

    case .loading:
      // A spinner, not a sentence about what was not found. Nothing has been found yet
      // because nothing has finished looking.
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading conversations…")
      }
      .font(.callout)
      .foregroundStyle(.secondary)

    case .loaded(let loaded) where loaded.isEmpty:
      // No hedge now. The read has come back, so this is the answer rather than a guess
      // at one while the answer was still on its way.
      Label("No conversations were found on this Mac.", systemImage: "info.circle")
        .font(.callout)
        .foregroundStyle(.secondary)

    case .loaded:
      Label("No conversation matches “\(chatSearch)”.", systemImage: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  /// What is chosen, kept on screen even when the search has filtered it out.
  ///
  /// Otherwise typing a new search makes the selection invisible while the Schedule button
  /// stays enabled: the form is armed and what it is aimed at is off screen.
  @ViewBuilder
  private var selectionSummary: some View {
    if let chosen = selectedChoice {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        Text(chosen.label.name)
        if let address = chosen.label.address {
          Text(address).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("Clear") { draft.selectedChatGUID = "" }
          .buttonStyle(.link)
      }
      .font(.callout)
      .lineLimit(1)
    }
  }

  /// Moves through the results without leaving the search field.
  ///
  /// The rule is `ChatPickerNavigation.selection(movedBy:in:from:)`, which answers rather
  /// than writing: a rule that mutates `@State` cannot be asked what it would do.
  private func moveSelection(by offset: Int) -> KeyPress.Result {
    guard
      let moved = ChatPickerNavigation.selection(
        movedBy: offset, in: filteredChats, from: draft.selectedChatGUID)
    else { return .ignored }
    draft.selectedChatGUID = moved
    return .handled
  }

  // MARK: - Chats

  /// Every conversation as a row, built when its inputs change rather than when it is read.
  ///
  /// Building one formats a phone number per participant and joins a search string, and this
  /// was a computed property read from five places: the results list, its height, the empty
  /// state, the arrow keys and Return. That is five passes over up to five hundred labelled
  /// conversations per keystroke, for a list that only changes when the chats or the contact
  /// names do.
  @State private var allChoices: [ConversationChoice] = []

  private func rebuildChoices() {
    allChoices = chats.compactMap { ConversationChoice(for: $0, contactNames: contactNames) }
  }

  /// Filtered live, with no debounce, because there is nothing to debounce: `chats` is
  /// already in memory and this is a substring match over at most 500 of them. A delay here
  /// would be latency added on purpose, and the reason to add one (not re-running a query
  /// per keystroke) does not apply to a query that is never run.
  private var filteredChats: [ConversationChoice] {
    ChatPickerNavigation.filter(allChoices, query: chatSearch)
  }

  private var selectedChoice: ConversationChoice? {
    guard !draft.selectedChatGUID.isEmpty else { return nil }
    // Searched across ALL chats rather than the filtered ones: a selection stays a
    // selection when the search that found it is typed over.
    return allChoices.first { $0.guid == draft.selectedChatGUID }
  }

  private func loadChats() async {
    await conversations.reload()
    // Rebuilt at each of the two points its inputs move, rather than through an
    // `.onChange`: `ChatSummary` is not `Equatable`, and making it so to watch a value
    // that changes exactly twice per presentation would be the tail wagging the dog.
    rebuildChoices()

    // Resolved AFTER the list is on screen rather than as part of it. The lookup is a
    // few hundred indexed probes and normally finishes before anyone opens the menu, but
    // whatever it costs it must not hold the conversation list back: an unlabelled list
    // is a perfectly usable one.
    //
    // Still `try?`, and deliberately: a name that could not be resolved falls back to the
    // formatted address, which is what this shows anyway when contact access was never
    // granted. There is nothing here for a person to act on, unlike a conversation list
    // that could not be read at all.
    guard let interfaces = await model.messaging.interfaces() else { return }
    let addresses = Array(Set(chats.flatMap(ConversationLabel.addresses(in:))))
    guard !addresses.isEmpty else { return }
    contactNames = (try? await interfaces.contact.displayNames(for: addresses)) ?? [:]
    // The second pass: the same rows, now labelled.
    rebuildChoices()
  }

  // MARK: - Saving

  private func save() async {
    // Scheduling touches only the app database: the chat.db gate belongs on `loadChats`,
    // which is what actually reads conversations.
    isSaving = true
    defer { isSaving = false }
    error = nil

    do {
      let scheduling = try model.messaging.scheduling.orServerNotRunning()
      // What the draft says to send; see `ScheduleDraft.request`.
      let built = draft.request
      _ = try await asOperator { try await scheduling.create(built) }
      onDone()
      dismiss()
    } catch {
      // The server's own words. "`scheduledFor` is in the past" tells someone exactly
      // what to change; "could not schedule" sends them guessing.
      self.error = DiagnosticText.sentence(for: error)
    }
  }
}

/// One conversation in the results list.
///
/// Its own view for the hover state: `@State` per row is what makes hover a row-local fact
/// rather than one more piece of the composer's state that every keystroke would invalidate.
private struct ConversationRow: View {

  let label: ConversationLabel
  let isSelected: Bool
  let select: () -> Void

  /// How far the rows sit inside the results box. The row's highlight takes this off the row
  /// radius, so its corners stay concentric with the box's rather than bulging past them.
  static let inset: CGFloat = 2

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 8) {
        // Always laid out, invisible when unselected: a checkmark that appears and
        // disappears would shift every name in the list sideways as you arrow down.
        Image(systemName: "checkmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tint)
          .opacity(isSelected ? 1 : 0)
          .frame(width: 12)

        Text(label.name)
          .lineLimit(1)

        if let address = label.address {
          // Truncates before the name does: the name is what identifies the row.
          Text(address)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(-1)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      // The whole row, not just the text, is the click target.
      .contentShape(Rectangle())
      .background(
        background,
        in: RoundedRectangle(cornerRadius: SettingsMetrics.rowCornerRadius - Self.inset))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var background: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(.tint.opacity(0.18)) }
    if isHovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
    return AnyShapeStyle(.clear)
  }
}
