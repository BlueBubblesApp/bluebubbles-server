//  DateFieldWindowTests
//  `dateField` on a paged read: which column `after` and `before` bracket.
//
//  The fixture seeds six messages, sent at +0 (MSG-0001), +30 (0004), +60 (0002), +90
//  (0006), +120 (0003) and +300 (0005) from `base`, each delivered a minute after it was
//  sent and the three sent by +60 read two minutes after. So a window opening at +150 holds
//  one message by `created`, three by `delivered`, two by `read` and five by `updated`, and
//  the page and its `total` must agree on each. Pages are in `date` order throughout.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Date field windows")
struct DateFieldWindowTests {

  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func rows(
    _ field: MessageRepository.MessageQuery.DateField, after: Date? = nil, before: Date? = nil,
    in fixture: ChatDatabaseFixture
  ) async throws -> (guids: [String], total: Int) {
    let query = MessageRepository.MessageQuery(
      after: after, before: before, ascending: true, dateField: field)
    return (
      try await fixture.repository.messages(query).map(\.guid),
      try await fixture.repository.messageCount(query)
    )
  }

  @Test("each field brackets its own column, and the total agrees with the page")
  func eachField() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let since = base.addingTimeInterval(150)

    let created = try await rows(.created, after: since, in: fixture)
    #expect(created.guids == ["MSG-0005"])
    #expect(created.total == 1)

    // Delivered at +150 (0006), +180 (0003) and +360 (0005).
    let delivered = try await rows(.delivered, after: since, in: fixture)
    #expect(delivered.guids == ["MSG-0006", "MSG-0003", "MSG-0005"])
    #expect(delivered.total == 3)

    // Read at +150 (0004) and +180 (0002); the other four were never read or read earlier.
    let read = try await rows(.read, after: since, in: fixture)
    #expect(read.guids == ["MSG-0004", "MSG-0002"])
    #expect(read.total == 2)

    let updated = try await rows(.updated, after: since, in: fixture)
    #expect(
      updated.guids == ["MSG-0004", "MSG-0002", "MSG-0006", "MSG-0003", "MSG-0005"])
    #expect(updated.total == 5)
  }

  @Test("edited and retracted bracket their own columns")
  func editedAndRetracted() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.setEdited(guid: "MSG-0001", at: base.addingTimeInterval(500))
    try await fixture.setEdited(guid: "MSG-0003", at: base.addingTimeInterval(700))
    try await fixture.setRetracted(guid: "MSG-0004", at: base.addingTimeInterval(600))
    let since = base.addingTimeInterval(550)

    let edited = try await rows(.edited, after: since, in: fixture)
    #expect(edited.guids == ["MSG-0003"])
    #expect(edited.total == 1)

    let retracted = try await rows(.retracted, after: since, in: fixture)
    #expect(retracted.guids == ["MSG-0004"])
    #expect(retracted.total == 1)

    // Nothing sent after +550, so the default window is untouched by either stamp.
    #expect(try await rows(.created, after: since, in: fixture).total == 0)
  }

  @Test("a date that is unset is never inside a before-only window")
  func unsetIsNotBeforeAnything() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    // Read at +120 (0001) and +150 (0004) are inside; the three with `date_read = 0` are
    // not, although zero is below any instant.
    let read = try await rows(.read, before: base.addingTimeInterval(160), in: fixture)
    #expect(read.guids == ["MSG-0001", "MSG-0004"])
    #expect(read.total == 2)
  }
}
