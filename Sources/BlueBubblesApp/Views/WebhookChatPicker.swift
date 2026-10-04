//  WebhookChatPicker
//  Choosing which conversations a webhook's chat events come from.
//
//  The same list the schedule composer offers (`ScheduleComposer.readChats`, labelled with
//  contact names where the address book has them and formatted addresses where it does not,
//  filtered live as you type) with one difference: a press ticks or unticks a conversation
//  rather than choosing the only one, because an endpoint can follow several.
//
//  What is chosen is listed under the search, whatever the search shows. Otherwise typing a
//  new search hides the selection while the Save button stays armed, which is the failure the
//  composer's `selectionSummary` exists for, multiplied by however many are ticked.
//
//  The conversation list is read only once "Only selected" is showing. A webhook that takes
//  every conversation, which is most of them, opens without reading five hundred chats it
//  will never show.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBCore
import BBInterfaces
import SwiftUI

struct WebhookChatPicker: View {

  @Bindable var model: AppModel
  @Binding var selection: WebhookChatSelection

  /// The conversation list, through the shared screen state, so a refused read and a Mac
  /// with no conversations reach `emptyResults` as different answers.
  @State private var conversations: ScreenModel<[ChatInterface.ChatSummary]>
  /// Every conversation as a row, rebuilt when the chats or the contact names arrive rather
  /// than on every keystroke. See `ScheduleComposer.allChoices`.
  @State private var allChoices: [ScheduleComposer.ChatChoice] = []
  @State private var search = ""

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: AppModel, selection: Binding<WebhookChatSelection>) {
    self.model = model
    _selection = selection
    _conversations = State(
      initialValue: ScreenModel { try await ScheduleComposer.readChats(model) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(title: "From") {
        Picker("", selection: $selection.isAllChats) {
          Text("All conversations").tag(true)
          Text("Only selected").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      SettingsDivider()

      if selection.isAllChats {
        SettingsFootnote(
          text: "Includes conversations started after you save this.",
          symbol: "info.circle"
        )
        .padding(.vertical, 4)
      } else {
        SettingsWideRow(
          title: "Conversations",
          help: "Search by name, number or email address. Choose as many as you like."
        ) {
          // Filtered ONCE per render and handed to the pieces that need it.
          let filtered = ChatPickerNavigation.filter(allChoices, query: search)
          searchField(filtered)
          resultsList(filtered)
        }
        .task { await load() }

        if !selection.selected.isEmpty {
          SettingsDivider()
          chosenList
        } else {
          SettingsDivider()
          SettingsFootnote(
            text: "Pick at least one conversation, or switch back to All conversations. "
              + "With none picked, this endpoint is sent no message, typing, read or group "
              + "events at all.",
            symbol: "exclamationmark.triangle",
            tone: .warning
          )
          .padding(.vertical, 4)
        }
      }
    }
  }

  // MARK: - Searching

  private func searchField(_ filtered: [ScheduleComposer.ChatChoice]) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("Search conversations", text: $search)
        .textFieldStyle(.plain)
        .onSubmit {
          // Return adds the top hit. It never REMOVES one: a key pressed to finish typing
          // must not quietly untick a conversation that was already chosen.
          if let first = filtered.first, !selection.contains(first.guid) {
            selection.toggle(first.guid)
          }
        }

      if !search.isEmpty {
        Button {
          search = ""
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

  private func resultsList(_ filtered: [ScheduleComposer.ChatChoice]) -> some View {
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
              isSelected: selection.contains(choice.guid)
            ) {
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                selection.toggle(choice.guid)
              }
            }
          }
        }
        .padding(2)
      }
    }
    .frame(height: resultsHeight(filtered))
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
  }

  /// Sized to the results, up to six rows, as the composer's is: a tall empty box pushes the
  /// list of chosen conversations off the bottom of the sheet.
  private func resultsHeight(_ filtered: [ScheduleComposer.ChatChoice]) -> CGFloat {
    let rows = min(max(filtered.count, 1), 6)
    return CGFloat(rows) * ScheduleComposer.rowHeight + 4
  }

  @ViewBuilder
  private var emptyResults: some View {
    // Switched on the read's own state rather than on whether the value is empty, so a read
    // in flight is not announced as "no conversations". See `ScheduleComposer.emptyResults`.
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

  /// Every chosen conversation, in the order it was chosen, each with a way to take it out.
  private var chosenList: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Chosen")
          .font(.callout.weight(.medium))
        Spacer()
        Button("Clear All") { selection.removeAll() }
          .buttonStyle(.link)
      }

      ForEach(selection.selected, id: \.self) { guid in
        HStack(spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
            let chosen = label(for: guid)
            Text(chosen.name)
            if let address = chosen.address {
              Text(address).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          Spacer(minLength: 8)
          Button("Remove") { selection.remove(guid) }
            .buttonStyle(.link)
        }
        .font(.callout)
        .lineLimit(1)
      }

      // Only once the list has been read: before that, every chosen conversation would be
      // "not in the list".
      if conversations.state.value != nil, !unmatched.isEmpty {
        SettingsFootnote(
          text: "Not found among the conversations on this Mac: "
            + "\(unmatched.count.counted("chosen conversation")). A deleted conversation "
            + "stays chosen until you remove it here.",
          symbol: "info.circle"
        )
      }
    }
    .padding(.vertical, 4)
  }

  private var unmatched: [String] {
    selection.unmatched(in: allChoices.map(\.guid))
  }

  /// A chosen conversation's label from the list, or one built from its GUID when the list
  /// does not have it (not read yet, or a chat that is gone).
  private func label(for guid: String) -> ScheduleComposer.ChatLabel {
    if let choice = allChoices.first(where: { ChatGUID.sameChat($0.guid, guid) }) {
      return choice.label
    }
    // A direct chat's GUID ends in the address, which is worth formatting; a group's ends in
    // an opaque `chat…` identifier, and the whole GUID is the most honest thing to show.
    guard let parsed = ChatGUID(guid), !parsed.isGroup else {
      return ScheduleComposer.ChatLabel(name: guid, address: nil)
    }
    return ScheduleComposer.ChatLabel(name: AddressFormatting.phone(parsed.address), address: nil)
  }

  // MARK: - Loading

  private func load() async {
    // Once per presentation: switching to All conversations and back must not re-read the
    // list. A read that failed has no value, so switching back does retry it.
    guard conversations.state.value == nil else { return }
    await conversations.reload()
    let chats = conversations.state.value ?? []
    allChoices = chats.compactMap { ScheduleComposer.choice(for: $0) }

    // The second pass, as in the composer: an unlabelled list is a usable one, so the
    // names never hold it back.
    let names = await ScheduleComposer.resolveContactNames(for: chats, model: model)
    guard !names.isEmpty else { return }
    allChoices = chats.compactMap { ScheduleComposer.choice(for: $0, contactNames: names) }
  }
}
