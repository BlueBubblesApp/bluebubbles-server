//  ConversationChoice
//  A conversation as the scheduling sheet offers it: what it is called, the address behind
//  the name, and what the search box matches it on.
//
//  Off the view so the labelling rules can be asserted, and so the second page that labels a
//  conversation (Home's activity cards) does not have to name the scheduling sheet to do it.
//  A type nested in a View is the second of the shapes that hide a decision from a test.

import BBCore
import BBInterfaces

struct ConversationChoice: Identifiable {
  let guid: String
  let label: ConversationLabel
  /// What the search box matches on, which is the label PLUS the raw addresses. Someone who
  /// knows the number and not the name (or who is looking at a number a client showed them)
  /// must still be able to find the conversation once it is labelled with a name.
  let searchText: String

  var id: String { guid }

  func matches(_ query: String) -> Bool {
    searchText.localizedCaseInsensitiveContains(query)
  }

  /// One row's worth of conversation, or nil for a chat with no GUID to schedule against.
  ///
  /// `ChatSummary.guid` is non-optional, so "no GUID" is unrepresentable, but an EMPTY one
  /// still is not, and a row that cannot be scheduled against is a dead end either way.
  init?(for chat: ChatInterface.ChatSummary, contactNames: [String: String] = [:]) {
    guard !chat.guid.isEmpty else { return nil }
    let label = ConversationLabel(for: chat, contactNames: contactNames)
    self.guid = chat.guid
    self.label = label
    // The GUID and the raw addresses are in here and not on screen. Someone pasting a
    // number from a client's UI, or a GUID from a log, is searching with the one spelling
    // the row does not show.
    self.searchText =
      ([label.plain, chat.guid] + ConversationLabel.addresses(in: chat)).joined(separator: " ")
  }
}

/// A conversation as the picker shows it: what it is called, and the address behind that
/// name when there is a single one worth showing.
struct ConversationLabel: Equatable {
  let name: String
  /// The formatted address, when it says something the name does not. Nil for a group, and
  /// nil when the name IS the address: repeating it there would read as a bug.
  let address: String?

  /// One line of plain text. What search matches on, and what anything that cannot take
  /// styling should show.
  ///
  /// The two parts stay separate everywhere else: a row renders them as two `Text`s so the
  /// address can be dimmed and truncated on its own.
  var plain: String { address.map { "\(name)  \($0)" } ?? name }

  init(name: String, address: String?) {
    self.name = name
    self.address = address
  }

  /// A chat's display name, or its participants, or its GUID: first one that says anything.
  ///
  /// A participant is named when the address book knows the address and left as the address
  /// when it does not, per participant rather than per chat: a group with one unknown number
  /// in it reads as two names and a number, which is more useful than giving up on the whole
  /// row because one address missed.
  ///
  /// A one-to-one conversation additionally keeps its address alongside the name. Two people
  /// in an address book can share a name, one person can have two numbers, and the fuzzy
  /// suffix match that resolves these can land on the wrong contact, so the thing being
  /// scheduled against stays visible rather than being replaced by a name that is only
  /// probably right. A group is left alone: the addresses are not one line's worth.
  init(for chat: ChatInterface.ChatSummary, contactNames: [String: String] = [:]) {
    let participants = Self.addresses(in: chat)

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

    guard participants.count == 1 else {
      self.init(name: name, address: nil)
      return
    }
    let formatted = AddressFormatting.phone(participants[0])
    self.init(name: name, address: name == formatted ? nil : formatted)
  }

  /// The addresses a chat is with.
  static func addresses(in chat: ChatInterface.ChatSummary) -> [String] {
    chat.participants
  }
}
