//  ConversationDirectory
//  The conversation list as a person sees it: every chat, newest first, with its
//  participants named.
//
//  One list for every screen that lets a person pick a conversation: the scheduled-message
//  composer, the transcript export page, a webhook's chat filter. Each used to resolve
//  names on its own (the composer called `chat.summaries` and then `contact.displayNames`
//  and joined them with rules of its own; the export built the same thing a second time),
//  and two copies of "what is this chat called" drift: one shows the address beside the
//  name, the other does not, and a person picking the same chat on two pages sees two
//  different rows.
//
//  A row is hydrated here, once: a contact name when the address book has the address and
//  the Contacts integration is on, a name the caller supplied otherwise, else the address
//  formatted for a person (a phone number grouped, an email as it is). The address is
//  always kept beside the name, because the fuzzy suffix match that resolves a number can
//  land on the wrong contact and the address is the thing a message will actually go to.
//
//  The read is three batched queries for the whole list (chats, participants, last
//  messages) plus one contact lookup for every address in it, never one per chat;
//  `ChatPageCostTests` holds that. The names are resolved as part of the read rather than in
//  a second pass: a few hundred indexed probes, measured well under the time a sheet takes to
//  appear, and a list that can be read without its names was a list two screens labelled
//  differently.

import BBContacts
import BBCore
import BBIMessage
import Foundation
import Logging

public struct ConversationDirectory: Sendable {

  /// Where a participant's name came from, so a consumer can decide whether to trust it or
  /// replace it with a name of its own.
  public enum NameSource: String, Sendable, Equatable, Codable {
    /// This server's contact index matched the address.
    case contacts
    /// The caller supplied the name with the request.
    case client
    /// Nothing named this address; `displayName` is the formatted address.
    case none
  }

  /// Somebody in a conversation. The address is the identity; the name is a decoration.
  public struct Participant: Sendable, Equatable, Hashable {
    /// The handle as `chat.db` stores it: an E.164 number or an email.
    public let address: String
    /// `iMessage`, `SMS` or `RCS`, when known.
    public let service: String?
    /// A contact or caller-supplied name, when there is one.
    public let name: String?
    public let nameSource: NameSource

    public init(
      address: String, service: String? = nil, name: String? = nil,
      nameSource: NameSource = .none
    ) {
      self.address = address
      self.service = service
      self.name = name
      self.nameSource = nameSource
    }

    /// The address as a person would write it: a phone number grouped, an email as it is.
    public var formattedAddress: String {
      address.contains("@") ? address : AddressFormatting.phone(address)
    }

    /// What a reader sees: the name when there is one, otherwise the formatted address. A
    /// business handle (`urn:biz:…`) reads as "Business", which is what the client shows.
    public var displayName: String {
      if let name, !name.isEmpty { return name }
      if address.hasPrefix("urn:biz") { return "Business" }
      return formattedAddress
    }
  }

  /// One conversation, as a picker lists it.
  public struct Conversation: Sendable, Equatable, Identifiable {
    public let guid: String
    /// The name the group was given, if any. Nil for a direct chat and an unnamed group.
    public let displayName: String?
    public let isGroup: Bool
    public let service: String?
    public let isArchived: Bool
    public let lastMessageDate: Date?
    /// Everyone in the conversation other than this Mac's own account.
    public let participants: [Participant]

    public var id: String { guid }

    public init(
      guid: String, displayName: String? = nil, isGroup: Bool, service: String? = nil,
      isArchived: Bool = false, lastMessageDate: Date? = nil, participants: [Participant]
    ) {
      self.guid = guid
      self.displayName = displayName.flatMap { $0.isEmpty ? nil : $0 }
      self.isGroup = isGroup
      self.service = service
      self.isArchived = isArchived
      self.lastMessageDate = lastMessageDate
      self.participants = participants
    }

    /// What the conversation is called: its own name, else its participants in order, each
    /// named when the address book knows them and left as a formatted address when it does
    /// not, else the GUID. Per participant rather than per chat, so one unknown number in a
    /// group does not cost the whole row its names.
    public var title: String {
      if let displayName { return displayName }
      guard !participants.isEmpty else { return guid }
      return participants.map(\.displayName).joined(separator: ", ")
    }

    /// The address to show beside the title, when it says something the title does not.
    ///
    /// A one-to-one conversation keeps its address alongside the name: two people in an
    /// address book can share a name, one person can have two numbers, and the suffix match
    /// that resolves a number can land on the wrong contact, so the thing a message goes to
    /// stays visible. Nil for a group (the addresses are not one line's worth) and nil when
    /// the title IS the address, which would otherwise show twice.
    public var subtitle: String? {
      guard participants.count == 1 else { return nil }
      let formatted = participants[0].formattedAddress
      return title == formatted ? nil : formatted
    }

    /// What a search matches on: the title, every spelling of every address (raw and
    /// formatted), every name, and the GUID. Someone pasting a number from a client, or a
    /// GUID from a log, is searching with the one spelling the row does not show.
    public var searchText: String {
      var pieces = [title, guid]
      if let subtitle { pieces.append(subtitle) }
      for participant in participants {
        pieces.append(participant.address)
        pieces.append(participant.formattedAddress)
        if let name = participant.name { pieces.append(name) }
      }
      return pieces.joined(separator: " ")
    }
  }

  private let repository: MessageRepository
  private let contacts: ContactIndex
  private let contactsEnabled: @Sendable () async -> Bool
  private let logger: Logger

  /// - Parameter contactsEnabled: whether the Contacts integration is on, asked per read,
  ///   because the directory is cached for the life of the server and the switch is not.
  public init(
    repository: MessageRepository,
    contacts: ContactIndex,
    contactsEnabled: @escaping @Sendable () async -> Bool = { true },
    logger: Logger = Logger(label: "bluebubbles.interface.conversations")
  ) {
    self.repository = repository
    self.contacts = contacts
    self.contactsEnabled = contactsEnabled
    self.logger = logger
  }

  // MARK: - Reading

  /// Every conversation, newest first, with its participants named.
  ///
  /// - Parameter names: names the caller already knows for addresses, which win over the
  ///   address book. A client with the phone's contacts knows people this Mac does not.
  public func list(
    limit: Int = 500, includeArchived: Bool = true, names: [String: String] = [:]
  ) async throws -> [Conversation] {
    let rows = try await repository.chats(
      includeArchived: includeArchived, limit: max(1, limit), offset: 0,
      sortByLastMessage: true)
    let participants = try await repository.participants(forChatRowIDs: rows.map(\.rowID))
    let lastMessages = try await repository.lastMessages(forChatRowIDs: rows.map(\.rowID))
    let addresses = Set(participants.values.flatMap { $0.map(\.id) })
    let resolved = await resolveNames(for: Array(addresses), overrides: names)
    return rows.map { row in
      Self.conversation(
        row, participants: participants[row.rowID] ?? [],
        lastMessage: lastMessages[row.rowID], names: resolved)
    }
  }

  /// One conversation by GUID, matched across every service-prefix spelling.
  public func conversation(guid: String, names: [String: String] = [:]) async throws
    -> Conversation
  {
    guard let row = try await repository.chat(guid: guid) else {
      throw InterfaceError.notFound("that conversation does not exist on this server")
    }
    let handles = try await repository.participants(forChatRowIDs: [row.rowID])[row.rowID] ?? []
    let resolved = await resolveNames(for: handles.map(\.id), overrides: names)
    let last = try await repository.lastMessages(forChatRowIDs: [row.rowID])
    return Self.conversation(
      row, participants: handles, lastMessage: last[row.rowID], names: resolved)
  }

  /// One address, named the same way a participant is. For a sender who is no longer in
  /// the conversation they wrote to.
  public func participant(
    address: String, service: String?, names: [String: String] = [:]
  ) async -> Participant {
    let resolved = await resolveNames(for: [address], overrides: names)
    return Self.participant(address: address, service: service, names: resolved)
  }

  // MARK: - Searching

  /// The rows a query admits: a case-insensitive match anywhere in `searchText`, or, for a
  /// query that is mostly digits, the digits of a phone number, so "555 0101" and
  /// "(555) 555-0101" both find `+15555550101`. A whitespace-only query is no query.
  public static func filter(_ conversations: [Conversation], query: String) -> [Conversation] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return conversations }
    let folded = ContactSearchText.fold(trimmed)
    let digits = trimmed.filter(\.isNumber)
    let matchesDigits = digits.count >= 3 && digits.count * 2 >= trimmed.count
    return conversations.filter { conversation in
      if ContactSearchText.fold(conversation.searchText).contains(folded) { return true }
      guard matchesDigits else { return false }
      return conversation.participants.contains {
        $0.address.filter(\.isNumber).contains(digits)
      }
    }
  }

  // MARK: - Names

  /// Resolved names by address, with where each came from.
  typealias ResolvedNames = [String: (name: String, source: NameSource)]

  static func conversation(
    _ row: ChatRow, participants: [HandleRow], lastMessage: IMessageRow?,
    names: ResolvedNames
  ) -> Conversation {
    Conversation(
      guid: row.guid, displayName: row.displayName, isGroup: row.isGroup,
      service: row.serviceName, isArchived: row.isArchived,
      lastMessageDate: lastMessage?.date?.date,
      participants: participants.map {
        participant(address: $0.id, service: $0.service, names: names)
      })
  }

  static func participant(address: String, service: String?, names: ResolvedNames)
    -> Participant
  {
    let known = names[address]
    return Participant(
      address: address, service: service, name: known?.name, nameSource: known?.source ?? .none)
  }

  /// The caller's names first, then the contact index for the rest.
  ///
  /// The index is asked only when the Contacts integration is on: with it off the index may
  /// still hold rows from before, and a person who switched it off did not switch it off
  /// for everything but pickers.
  private func resolveNames(
    for addresses: [String], overrides: [String: String]
  ) async -> ResolvedNames {
    var resolved: ResolvedNames = [:]
    for (address, name) in overrides where !name.isEmpty {
      resolved[address] = (name, .client)
    }
    let unresolved = addresses.filter { resolved[$0] == nil }
    guard !unresolved.isEmpty, await contactsEnabled() else { return resolved }
    do {
      let records = try await contacts.findContacts(addresses: unresolved)
      for (address, record) in records {
        if let name = ContactInterface.displayName(for: record), !name.isEmpty {
          resolved[address] = (name, .contacts)
        }
      }
    } catch {
      // A list of addresses is still a list; the failure is logged and the read goes on.
      // No address is in the log line.
      logger.warning(
        "Contact lookup failed while naming conversations; addresses will be shown",
        metadata: ["reason": .string(String(describing: error))])
    }
    return resolved
  }
}
