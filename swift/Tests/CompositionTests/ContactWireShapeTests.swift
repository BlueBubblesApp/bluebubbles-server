//  ContactWireShapeTests
//  `GET /api/v1/contact` — the eleven-key shape of `ContactInterface.mapContacts`.
//
//  This diverged five ways at once and the parity harness reported only "552 rows against
//  587", because it stops at a length mismatch and never reaches the elements. A row-count
//  difference between two machines' address books reads as an environment difference, so it
//  was nearly signed off as one. Measured against a live Electron server.
//
//  Reference: packages/server/src/server/api/interfaces/contactInterface.ts:55-97

import BBContacts
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Contact wire shape")
struct ContactWireShapeTests {

  private func record(
    firstName: String? = "Aaron",
    lastName: String? = "Bierlein",
    displayName: String? = nil,
    nickname: String? = nil,
    birthday: String? = nil
  ) -> ContactRecord {
    ContactRecord(
      id: "882BB792-0AD7-4F41-9C99-2E5F2BE8AEDF",
      source: .local,
      firstName: firstName,
      lastName: lastName,
      displayName: displayName,
      nickname: nickname,
      birthday: birthday,
      externalID: nil,
      phoneNumbers: ["+1-202-555-0143"],
      emailAddresses: []
    )
  }

  @Test("The default projection matches the reference's key set")
  func keySetMatchesNode() {
    let json = ContactInterface.serialize(record())

    #expect(
      json.objectKeys == [
        "phoneNumbers", "emails", "firstName", "lastName", "displayName",
        "avatar", "sourceType", "id", "externalId",
      ])
  }

  /// `avatar` is never absent: the reference defaults it to `""`. It was being omitted, so a
  /// client rendering an avatar found no key where it has always found one.
  @Test("avatar is always present, empty rather than null")
  func avatarIsAlwaysPresent() {
    #expect(ContactInterface.serialize(record())["avatar"] == .string(""))
  }

  /// `nickname` and `birthday` are ABSENT when unset, not null.
  ///
  /// A JavaScript artifact being reproduced deliberately: `mapContacts` assigns them from
  /// `contact?.nickname`, and `JSON.stringify` drops a key whose value is `undefined`.
  /// `externalId` keeps its key because it reads a real column and is null, not undefined.
  @Test("nickname and birthday are absent when unset, present when set")
  func optionalKeysFollowTheReference() {
    let bare = ContactInterface.serialize(record())
    #expect(!bare.objectKeys.contains("nickname"))
    #expect(!bare.objectKeys.contains("birthday"))
    #expect(bare.objectKeys.contains("externalId"))
    #expect(bare["externalId"] == .null)

    let full = ContactInterface.serialize(record(nickname: "Az", birthday: "1990-01-01"))
    #expect(full["nickname"] == .string("Az"))
    #expect(full["birthday"] == .string("1990-01-01"))
  }

  /// Addresses are `{address, id}`. The `id` was missing entirely.
  @Test("Phone numbers and emails carry an id alongside the address")
  func addressesCarryAnID() {
    let json = ContactInterface.serialize(record())
    let phone = json["phoneNumbers"]?[0]

    #expect(phone?.objectKeys == ["address", "id"])
    #expect(phone?["address"] == .string("+1-202-555-0143"))
    #expect(phone?["id"] == .null)
  }

  /// Derived from the name parts when the record has none — clients render this field
  /// directly, so returning null gives a contact list of blanks.
  @Test("displayName falls back to the name parts, then the nickname")
  func displayNameIsDerived() {
    #expect(ContactInterface.displayName(for: record()) == "Aaron Bierlein")
    #expect(ContactInterface.displayName(for: record(lastName: nil)) == "Aaron")
    #expect(
      ContactInterface.displayName(for: record(firstName: nil, lastName: nil, nickname: "Az"))
        == "Az"
    )
    // An explicit name always wins.
    #expect(
      ContactInterface.displayName(for: record(displayName: "Az B.")) == "Az B."
    )
    #expect(ContactInterface.displayName(for: record(firstName: nil, lastName: nil)) == nil)
  }
}
