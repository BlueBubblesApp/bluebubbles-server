//  ContactRecord
//  The contact model: `ContactSource`, `ContactAccount`, `AddressKind` and `ContactRecord`.
//
//  Its own file so a caller handed a record opens its shape and not the indexed lookup that
//  produced it (`ContactIndex.swift`). Nothing here touches the database; a record is what
//  the index stores and answers with.

import Foundation

public enum ContactSource: Int, Sendable, Codable, CaseIterable {
  /// Highest precedence: it is the address book the user actually curates.
  ///
  /// This covers EVERY account configured in Contacts: iCloud, on-device, and CardDAV
  /// accounts including Google. There is deliberately no separate Google case: the current
  /// server has one only because `node-mac-contacts` cannot see CardDAV contacts, and that
  /// is a bug in how it enumerates rather than something the address book withholds.
  case macOS = 0
  /// Contacts created through POST /api/v1/contact. Lowest precedence.
  ///
  /// Raw value 2, with 1 left unused where the Google source was: the numbers are stored
  /// in the database, so renumbering would silently reinterpret existing rows.
  case local = 2

  /// What a person calls it: the Account column's fallback, and the label the bulk control
  /// groups under. Here rather than in the app because the SQL that groups by it needs the
  /// same string, and two spellings would put a group in the menu that no row displays.
  public var label: String {
    switch self {
    case .macOS: "Address Book"
    case .local: "Local"
    }
  }
}

/// Which account in Contacts a record synced from.
///
/// `ContactSource` answers "did this come from the address book or from our own API", which is
/// a different question and is frozen into the wire format as `db`/`api`. This answers "which
/// account in the address book", which is what a user actually wants to know when two entries
/// for the same person disagree.
///
/// The name is kept verbatim alongside the inferred kind ON PURPOSE. Contacts.framework exposes
/// a container's type (`local`, `cardDAV`, `exchange`) but not the service behind it: iCloud
/// and Google are both CardDAV, so the kind is a heuristic over the container name. Keeping the
/// name means a wrong guess is visible rather than authoritative.
public struct ContactAccount: Sendable, Codable, Equatable {

  public enum Kind: String, Sendable, Codable, CaseIterable {
    case onThisMac
    case iCloud
    case google
    case exchange
    case other
    /// Not from the address book at all: created through POST /api/v1/contact.
    case server
  }

  public var kind: Kind
  /// The container's name as Contacts reports it, when there is one.
  public var name: String?

  public init(kind: Kind, name: String? = nil) {
    self.kind = kind
    self.name = name
  }

  /// What to show a user.
  public var label: String {
    switch kind {
    case .onThisMac: "On this Mac"
    case .iCloud: "iCloud"
    case .google: "Google"
    case .exchange: "Exchange"
    // The container's own name is more use than the word "other".
    case .other: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Other account"
    case .server: "Local"
    }
  }

  /// Infers the account from a container's type and name.
  ///
  /// `containerType` is the raw `CNContainerType` value, passed as a string so this stays
  /// testable without Contacts.framework and without a platform gate.
  public static func infer(containerType: String, name: String?) -> ContactAccount {
    let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
    let lowered = trimmed.lowercased()

    switch containerType {
    case "local":
      return ContactAccount(kind: .onThisMac, name: trimmed.isEmpty ? nil : trimmed)
    case "exchange":
      return ContactAccount(kind: .exchange, name: trimmed.isEmpty ? nil : trimmed)
    case "cardDAV":
      // Both iCloud and Google arrive as CardDAV, so the name is the only signal.
      if lowered.contains("google") || lowered.contains("gmail") {
        return ContactAccount(kind: .google, name: trimmed)
      }
      // "Card" is what iCloud's container has been called since the AddressBook days;
      // an empty name is the other way it shows up.
      if lowered.contains("icloud") || lowered == "card" || trimmed.isEmpty {
        return ContactAccount(kind: .iCloud, name: trimmed.isEmpty ? nil : trimmed)
      }
      return ContactAccount(kind: .other, name: trimmed)
    default:
      return ContactAccount(kind: .other, name: trimmed.isEmpty ? nil : trimmed)
    }
  }
}

public enum AddressKind: Int, Sendable, Codable {
  case phone = 0
  case email = 1
}

public struct ContactRecord: Sendable, Identifiable, Codable {
  public let id: String
  public let source: ContactSource
  public var firstName: String?
  public var lastName: String?
  public var displayName: String?
  public var nickname: String?
  public var birthday: String?
  /// The identifier in the source system. Identity keys off THIS rather than off the name,
  /// so two people with the same name do not collide.
  public var externalID: String?
  /// The id as clients see it: the stored key with the address-book prefix removed.
  ///
  /// A computed projection rather than a second stored column, because there is only one
  /// identifier: the prefix is a namespacing detail of sharing one table between two
  /// sources, and nothing outside storage should know about it.
  public var wireID: String {
    id.hasPrefix(ContactIndex.addressBookPrefix)
      ? String(id.dropFirst(ContactIndex.addressBookPrefix.count)) : id
  }
  public var phoneNumbers: [String]
  public var emailAddresses: [String]
  /// Which address-book account this came from, when it came from one.
  public var account: ContactAccount?

  public init(
    id: String,
    source: ContactSource,
    firstName: String? = nil,
    lastName: String? = nil,
    displayName: String? = nil,
    nickname: String? = nil,
    birthday: String? = nil,
    externalID: String? = nil,
    phoneNumbers: [String] = [],
    emailAddresses: [String] = [],
    account: ContactAccount? = nil
  ) {
    self.id = id
    self.source = source
    self.firstName = firstName
    self.lastName = lastName
    self.displayName = displayName
    self.nickname = nickname
    self.birthday = birthday
    self.externalID = externalID
    self.phoneNumbers = phoneNumbers
    self.emailAddresses = emailAddresses
    self.account = account
  }
}
