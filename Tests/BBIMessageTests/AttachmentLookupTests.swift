//  AttachmentLookupTests
//  `MessageRepository.attachment(guid:)` resolves every GUID the reference resolves.
//
//  Messages renames an attachment after the send and keeps the first GUID in
//  `original_guid`; a client holds whichever it was told first. The reference answers
//  `GET /attachment/:guid` for the current GUID, the original, a case variant of either, and
//  for a longer GUID its last 36 characters. A lookup stricter than that is a 404 for a
//  shipped client, which is how this suite came to exist.

import Testing

@testable import BBIMessage

@Suite("Attachment lookup")
struct AttachmentLookupTests {

  /// The seeded attachment, renamed the way Messages renames a sent sticker.
  static let renamed = "at_0_00000000-0000-4000-8000-000000000003"

  @Test("resolves the current GUID, the original, and a case variant of each")
  func renamedAttachment() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.renameAttachment("ATT-0001", to: Self.renamed)

    for requested in ["ATT-0001", "att-0001", Self.renamed, Self.renamed.lowercased()] {
      let row = try await fixture.repository.attachment(guid: requested)
      #expect(row?.guid == Self.renamed, "requested \(requested)")
      #expect(row?.originalGUID == "ATT-0001", "requested \(requested)")
    }
  }

  @Test("a GUID longer than a UUID also resolves by its last 36 characters")
  func suffixOfAPrefixedGUID() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.renameAttachment("ATT-0001", to: Self.renamed)

    // Another device's prefix for the same row.
    let otherPrefix = "at_1_00000000-0000-4000-8000-000000000003"
    #expect(try await fixture.repository.attachment(guid: otherPrefix)?.guid == Self.renamed)
    // The bare 36 characters are a suffix of the row's GUID too.
    let bare = String(Self.renamed.suffix(36))
    #expect(try await fixture.repository.attachment(guid: bare)?.guid == Self.renamed)
  }

  @Test("an exact match wins over a row that merely ends in the request")
  func exactBeforeSuffix() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.addAttachment(guid: "at_0_ATT-0001", onMessage: "MSG-0001")

    #expect(try await fixture.repository.attachment(guid: "ATT-0001")?.guid == "ATT-0001")
    #expect(
      try await fixture.repository.attachment(guid: "at_0_ATT-0001")?.guid == "at_0_ATT-0001")
  }

  @Test("a GUID nothing ends in is not found")
  func unknown() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    #expect(try await fixture.repository.attachment(guid: "ATT-9999") == nil)
  }
}
