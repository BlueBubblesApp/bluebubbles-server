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
//  best-effort layer over the same list: an address with no contact — including every address
//  on a server that was never granted contact access — keeps the formatted number it has
//  always shown, so the screen degrades to exactly what it was rather than to something worse.
//  A one-to-one conversation shows the address after the name, in secondary colour, because a
//  name is the friendly answer and the address is the true one.
//
//  The conversation is chosen from a LIVE-FILTERED LIST rather than a search box feeding a
//  pop-up menu. The menu version made you type, then open a separate control to find out what
//  you had typed — the results were hidden behind a click, so the search box could not tell
//  you it had narrowed to one thing, or to nothing. Results are on screen as you type, the
//  most recent conversations are there before you type at all, and arrow keys move through
//  them without leaving the field.
//
//  See `.claude/docs/architecture.md`.

import BBHandlers
import BBInterfaces
import BBSerialization
import BlueBubblesServerCore
import SwiftUI

struct ScheduleComposer: View {

  @Bindable var model: AppModel
  let onDone: () -> Void

  @Environment(\.dismiss) private var dismiss

  private enum Recipient: String, CaseIterable, Identifiable {
    case existingChat = "A conversation"
    case address = "An address"
    var id: String { rawValue }
  }

  private enum Repeats: String, CaseIterable, Identifiable {
    case never = "Never"
    case hourly, daily, weekly, monthly, yearly
    var id: String { rawValue }
    var title: String { self == .never ? "Never" : rawValue.capitalized }
    /// The wire value, frozen: clients scheduled against these names.
    var intervalType: String? { self == .never ? nil : rawValue }
  }

  @State private var recipient: Recipient = .existingChat
  @State private var chats: [ChatInterface.ChatSummary] = []
  /// Address -> contact name, for the addresses these chats are with. Empty when contact
  /// access was never granted, or when nobody in the list is in the address book.
  @State private var contactNames: [String: String] = [:]
  @State private var selectedChatGUID = ""
  @State private var chatSearch = ""
  @FocusState private var searchIsFocused: Bool
  @State private var address = ""
  @State private var service = "iMessage"
  @State private var messageBody = ""
  // Rounded to the next quarter hour: a default of "right now" is always in the past by the
  // time the sheet is filled in, and `create` rejects that.
  @State private var sendAt = Date().addingTimeInterval(900)
  @State private var repeats: Repeats = .never
  @State private var every = 1
  @State private var isSaving = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
          recipientSection
          messageSection
          timingSection
        }
        .padding(SettingsMetrics.pagePadding)
      }
      Divider()
      footer
    }
    .frame(width: 640, height: 660)
    .task { await loadChats() }
  }

  // MARK: - Chrome

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Schedule a Message").font(.title3.weight(.semibold))
      Text("It is stored on the server and sent even if this window is closed.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Schedule") { Task { await save() } }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!canSave || isSaving)
    }
    .padding(16)
  }

  // MARK: - Sections

  private var recipientSection: some View {
    SettingsSection("Send to") {
      SettingsRow(title: "Recipient") {
        Picker("", selection: $recipient) {
          ForEach(Recipient.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      SettingsDivider()

      if recipient == .existingChat {
        SettingsWideRow(
          title: "Conversation",
          help: "Only conversations that already exist. Start a new one in Messages "
            + "first, or send to an address below."
        ) {
          searchField
          resultsList
          selectionSummary
        }
      } else {
        SettingsRow(title: "Address", help: "A phone number or email address.") {
          TextField("+15550101234", text: $address)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
        }
        SettingsDivider()
        SettingsRow(title: "Service") {
          Picker("", selection: $service) {
            Text("iMessage").tag("iMessage")
            Text("SMS").tag("SMS")
          }
          .labelsHidden()
          .controlSize(.large)
          .frame(maxWidth: 200)
        }
        if !address.trimmingCharacters(in: .whitespaces).isEmpty {
          SettingsDivider()
          // Shown rather than assembled invisibly: if this is wrong, it fails at
          // send time and the user is not there to see it.
          SettingsRow(title: "Will send to") {
            Text(composedGUID)
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
        TextEditor(text: $messageBody)
          .font(.body)
          .frame(minHeight: 110)
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private var timingSection: some View {
    SettingsSection("When") {
      SettingsRow(
        title: "Send at",
        help: "Must be in the future — the server rejects a past time rather than "
          + "sending immediately."
      ) {
        DatePicker("", selection: $sendAt, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .controlSize(.large)
      }

      SettingsDivider()

      SettingsRow(title: "Repeat") {
        Picker("", selection: $repeats) {
          ForEach(Repeats.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 200)
      }

      if repeats != .never {
        SettingsDivider()
        SettingsRow(
          title: "Every",
          help: "How many \(repeats.rawValue) periods between sends."
        ) {
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            TextField("", value: $every, format: .number)
              .textFieldStyle(.roundedBorder)
              .controlSize(.large)
              .frame(width: 90)
            Stepper("", value: $every, in: 1...52).labelsHidden()
          }
        }
        SettingsDivider()
        // The one genuinely surprising behaviour, stated where it is chosen: the old
        // server treats a month as 30 fixed days and a year as 365, and this server
        // reproduces that so existing schedules do not shift.
        SettingsFootnote(
          text: repeats == .monthly || repeats == .yearly
            ? "Months are 30 days and years are 365 days, matching the previous "
              + "server — not calendar months."
            : "Repeats until you cancel it.",
          symbol: "info.circle"
        )
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Choosing a conversation

  /// A search box, not a `TextField` with a magnifying glass drawn on it.
  ///
  /// The arrow keys are bound HERE rather than on the list because this is what holds focus:
  /// the whole point of the rewrite is that the list never takes focus away from typing, so
  /// a key handler on the list would only fire once someone had already clicked into it.
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)

      TextField("Search conversations", text: $chatSearch)
        .textFieldStyle(.plain)
        .focused($searchIsFocused)
        .onSubmit {
          // Return takes the top hit when nothing is chosen yet. It is otherwise
          // the sheet's default action, which is what someone finishing the form
          // expects it to be.
          if selectedChatGUID.isEmpty, let first = filteredChats.first {
            selectedChatGUID = first.guid
          }
        }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }

      if !chatSearch.isEmpty {
        Button {
          chatSearch = ""
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
    // Focused on open, because this is the first thing the sheet asks for and typing is
    // how it gets answered.
    .task { searchIsFocused = true }
  }

  private var resultsList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if filteredChats.isEmpty {
          emptyResults
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(filteredChats) { choice in
              ConversationRow(
                label: choice.label,
                isSelected: choice.guid == selectedChatGUID
              ) { selectedChatGUID = choice.guid }
              .id(choice.guid)
            }
          }
          .padding(2)
        }
      }
      .frame(height: resultsHeight)
      .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1)
      )
      // Follows an arrow-key move out of view. Without this, holding the down arrow
      // walks the selection past the bottom of a box that never scrolls.
      .onChange(of: selectedChatGUID) { _, guid in
        guard !guid.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(guid, anchor: .center) }
      }
    }
  }

  /// Sized to the results, up to six rows.
  ///
  /// A fixed-height box would be mostly empty space on a search that narrowed to one hit,
  /// and this sheet has two more sections under it that a tall empty box pushes off screen.
  private var resultsHeight: CGFloat {
    let rows = max(filteredChats.count, 1)
    return min(CGFloat(rows) * Self.rowHeight, CGFloat(6) * Self.rowHeight) + 4
  }

  private static let rowHeight: CGFloat = 26

  @ViewBuilder
  private var emptyResults: some View {
    // Two different situations that look identical if both say "nothing here": the server
    // has not read the message database yet, or it has and the search matched nothing.
    if chats.isEmpty {
      Label(
        "No conversations were found. The server may still be reading the message "
          + "database.",
        systemImage: "info.circle"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    } else {
      Label("No conversation matches “\(chatSearch)”.", systemImage: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  /// What is currently chosen, kept on screen even when the search has filtered it out.
  ///
  /// Otherwise typing a new search makes the selection invisible while the Schedule button
  /// stays enabled — the form is armed and what it is aimed at is off screen.
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
        Button("Clear") { selectedChatGUID = "" }
          .buttonStyle(.link)
      }
      .font(.callout)
      .lineLimit(1)
    }
  }

  /// Moves through the results without leaving the search field.
  private func moveSelection(by offset: Int) -> KeyPress.Result {
    let choices = filteredChats
    guard !choices.isEmpty else { return .ignored }
    guard let current = choices.firstIndex(where: { $0.guid == selectedChatGUID }) else {
      // Nothing selected yet: down enters at the top, up enters at the bottom.
      selectedChatGUID = (offset > 0 ? choices.first : choices.last)?.guid ?? ""
      return .handled
    }
    // Clamped rather than wrapped. Wrapping from the last result back to the first looks
    // like the list jumped somewhere else.
    selectedChatGUID = choices[min(max(current + offset, 0), choices.count - 1)].guid
    return .handled
  }

  // MARK: - Chats

  struct ChatChoice: Identifiable {
    let guid: String
    let label: ChatLabel
    /// What the search box matches on, which is the label PLUS the raw addresses. Someone
    /// who knows the number and not the name — or who is looking at a number a client
    /// showed them — must still be able to find the conversation once it is labelled
    /// "Aaron Bierlein".
    let searchText: String

    var id: String { guid }

    func matches(_ query: String) -> Bool {
      searchText.localizedCaseInsensitiveContains(query)
    }
  }

  /// One row's worth of conversation, or nil for a chat with no GUID to schedule against.
  nonisolated static func choice(
    for chat: ChatInterface.ChatSummary, contactNames: [String: String] = [:]
  ) -> ChatChoice? {
    // `ChatSummary.guid` is non-optional, so "no GUID" is now unrepresentable — but an
    // EMPTY one still is not, and a row that cannot be scheduled against is a dead end
    // either way.
    let guid = chat.guid
    guard !guid.isEmpty else { return nil }
    let label = label(for: chat, contactNames: contactNames)
    return ChatChoice(
      guid: guid,
      label: label,
      // The GUID and the raw addresses are in here and not on screen. Someone pasting
      // a number from a client's UI, or a GUID from a log, is searching with the one
      // spelling the row does not show.
      searchText: ([label.plain, guid] + addresses(in: chat)).joined(separator: " ")
    )
  }

  private var allChoices: [ChatChoice] {
    chats.compactMap { Self.choice(for: $0, contactNames: contactNames) }
  }

  /// Filtered live, with no debounce, because there is nothing to debounce: `chats` is
  /// already in memory and this is a substring match over at most 500 of them. A delay here
  /// would be latency added on purpose, and the reason to add one — not re-running a query
  /// per keystroke — does not apply to a query that is never run.
  var filteredChats: [ChatChoice] {
    let query = chatSearch.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return allChoices }
    return allChoices.filter { $0.matches(query) }
  }

  private var selectedChoice: ChatChoice? {
    guard !selectedChatGUID.isEmpty else { return nil }
    // Searched across ALL chats rather than the filtered ones: a selection stays a
    // selection when the search that found it is typed over.
    return allChoices.first { $0.guid == selectedChatGUID }
  }

  /// A conversation as the picker shows it: what it is called, and the address behind that
  /// name when there is a single one worth showing.
  struct ChatLabel: Equatable {
    let name: String
    /// The formatted address, when it says something the name does not. Nil for a group,
    /// and nil when the name IS the address — repeating it there would read as a bug.
    let address: String?

    /// One line of plain text. What search matches on, and what anything that cannot take
    /// styling should show.
    ///
    /// The two parts stay separate everywhere else: a row renders them as two `Text`s so
    /// the address can be dimmed and truncated on its own. A single attributed string would
    /// only be needed for a pop-up menu item, which takes a title rather than a view —
    /// nothing renders these in a menu, so two views are the simpler thing.
    var plain: String { address.map { "\(name)  \($0)" } ?? name }
  }

  /// The addresses a chat is with.
  ///
  /// `nonisolated`, along with `label` below, because neither reads view state — they are
  /// pure functions over a chat record, and being able to call them off the main actor is
  /// what lets a test cover the fallback chain directly.
  nonisolated static func addresses(in chat: ChatInterface.ChatSummary) -> [String] {
    chat.participants
  }

  /// A chat's display name, or its participants, or its GUID — first one that says anything.
  ///
  /// A participant is named when the address book knows the address and left as the address
  /// when it does not, per participant rather than per chat: a group with one unknown number
  /// in it reads "Aaron Bierlein, Kyle Sheets, (555) 010-1234", which is more useful than
  /// giving up on the whole row because one address missed.
  ///
  /// A one-to-one conversation additionally keeps its address alongside the name. Two people
  /// in an address book can share a name, one person can have two numbers, and the fuzzy
  /// suffix match that resolves these can land on the wrong contact — so the thing being
  /// scheduled against stays visible rather than being replaced by a name that is only
  /// probably right. A group is left alone: the addresses are not one line's worth.
  nonisolated static func label(
    for chat: ChatInterface.ChatSummary, contactNames: [String: String] = [:]
  ) -> ChatLabel {
    let participants = addresses(in: chat)

    let name: String
    if let displayName = chat.displayName, !displayName.isEmpty {
      name = displayName
    } else if !participants.isEmpty {
      name =
        participants
        .map { contactNames[$0] ?? AddressFormatting.phone($0) }
        .joined(separator: ", ")
    } else {
      name = chat.guid
    }

    guard participants.count == 1 else { return ChatLabel(name: name, address: nil) }
    let formatted = AddressFormatting.phone(participants[0])
    return ChatLabel(name: name, address: name == formatted ? nil : formatted)
  }

  private func loadChats() async {
    guard let interfaces = await model.interfaces() else { return }
    chats = (try? await interfaces.chat.summaries(limit: 500)) ?? []

    // Resolved AFTER the list is on screen rather than as part of it. The lookup is a
    // few hundred indexed probes and normally finishes before anyone opens the menu, but
    // whatever it costs it must not hold the conversation list back — an unlabelled list
    // is the state this screen shipped in, and it is a perfectly usable one.
    let addresses = Array(Set(chats.flatMap(Self.addresses(in:))))
    guard !addresses.isEmpty else { return }
    contactNames = (try? await interfaces.contact.displayNames(for: addresses)) ?? [:]
  }

  // MARK: - Saving

  private var composedGUID: String {
    "\(service);-;\(address.trimmingCharacters(in: .whitespaces))"
  }

  private var targetGUID: String {
    recipient == .existingChat ? selectedChatGUID : composedGUID
  }

  private var canSave: Bool {
    !messageBody.trimmingCharacters(in: .whitespaces).isEmpty
      && !(recipient == .existingChat ? selectedChatGUID : address)
        .trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func save() async {
    // Scheduling touches only the app database — the chat.db gate belongs on `loadChats`,
    // which is what actually reads conversations.
    guard let scheduling = model.scheduling else { return }
    isSaving = true
    defer { isSaving = false }
    error = nil

    var payload = JSONObjectBuilder()
    payload.set("chatGuid", .string(targetGUID))
    payload.set("message", .string(messageBody))

    var request = JSONObjectBuilder()
    request.set("type", .string("send-message"))
    request.set("payload", payload.build())
    request.set("scheduledFor", .int64(Int64(sendAt.timeIntervalSince1970 * 1000)))
    if let intervalType = repeats.intervalType {
      request.set(
        "schedule",
        .object([
          "type": .string("recurring"),
          "intervalType": .string(intervalType),
          "interval": .int64(Int64(max(1, every))),
        ]))
    }

    do {
      _ = try await scheduling.create(request.build())
      onDone()
      dismiss()
    } catch {
      // The server's own words. "`scheduledFor` is in the past" tells someone exactly
      // what to change; "could not schedule" sends them guessing.
      self.error = String(describing: error)
    }
  }
}

/// One conversation in the results list.
///
/// Its own view for the hover state: `@State` per row is what makes hover a row-local fact
/// rather than one more piece of the composer's state that every keystroke would invalidate.
private struct ConversationRow: View {

  let label: ScheduleComposer.ChatLabel
  let isSelected: Bool
  let select: () -> Void

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
          // Truncates before the name does — the name is what identifies the row.
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
      .background(background, in: RoundedRectangle(cornerRadius: 6))
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
