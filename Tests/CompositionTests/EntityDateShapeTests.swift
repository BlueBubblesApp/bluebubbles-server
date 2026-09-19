//  EntityDateShapeTests
//  Which dates are ISO strings and which are epoch milliseconds.
//
//  Two conventions on one API, and the line between them is not a style choice — it is a
//  consequence of how the reference builds each response:
//
//    - A SERIALIZER converts by hand with `.getTime()`, so the wire carries a NUMBER. That is
//      most dates: `message.dateCreated`, the chat timestamps.
//    - A route that returns a TypeORM **entity** converts nothing, so `JSON.stringify` renders
//      the JS `Date` as an ISO STRING.
//
//  `webhook.created` is the second kind and shipped as the first. The entity carries the
//  identical `@CreateDateColumn()` that produces an ISO `created` on a scheduled message, and
//  a node-recorded fixture shows that string directly. A client calling `DateTime.parse` on
//  the number throws — the failure is total, not cosmetic, which is why this is worth pinning
//  rather than trusting the comment in `WireDate`.
//
//  The webhook fixtures are all self-recorded, so the replay harness compared this field to
//  our own output and agreed with itself. That is the gap a source-level assertion fills.

import BBSerialization
import Foundation
import Testing

// `@testable` only to reach the memberwise initialiser; what is asserted is the public
// `json` shape a client receives.
@testable import BBAppStore

@Suite("Entity date shapes")
struct EntityDateShapeTests {

  private func webhookJSON(created: Date) -> [String: JSONValue] {
    let webhook = Webhook(
      id: 1, url: "https://hooks.example.com/x", events: "[\"*\"]", createdAt: created,
      followRedirects: Webhook.defaultFollowRedirects)
    guard case .object(let fields) = webhook.json else {
      Issue.record("a webhook must serialize as an object")
      return [:]
    }
    return fields
  }

  @Test("webhook.created is an ISO 8601 string, not a number")
  func webhookCreatedIsISO() {
    let created = Date(timeIntervalSince1970: 1_756_567_000)
    let fields = webhookJSON(created: created)

    guard case .string(let value) = fields["created"] else {
      Issue.record("created must be a string, got \(String(describing: fields["created"]))")
      return
    }
    #expect(value == WireDate.iso(created))
    // The shape a client parses, asserted rather than implied by the round trip: `Z`, and
    // milliseconds, because that is what `JSON.stringify(new Date())` emits.
    #expect(value.hasSuffix("Z"))
    #expect(value.contains("."), "milliseconds are part of the format: \(value)")
  }

  @Test("It round-trips through the parser a client would use")
  func webhookCreatedParsesBack() {
    let created = Date(timeIntervalSince1970: 1_756_567_000)
    guard case .string(let value) = webhookJSON(created: created)["created"] else {
      Issue.record("created must be a string")
      return
    }
    let parsed = WireDate.parse(value)
    #expect(parsed != nil, "a value we emit must be one we can read: \(value)")
    #expect(abs((parsed ?? .distantPast).timeIntervalSince(created)) < 0.001)
  }

  @Test("An epoch-millisecond number would not survive the client's parser")
  func theOldShapeWasUnparseable() {
    // Why this is a break and not a difference. The number is a perfectly good instant and
    // completely unreadable to the thing on the other end, which is the whole argument for
    // the reference's format being the contract rather than the reference's format being
    // one valid option.
    let created = Date(timeIntervalSince1970: 1_756_567_000)
    let asMilliseconds = String(Int64(created.timeIntervalSince1970 * 1000))
    #expect(WireDate.parse(asMilliseconds) == nil)
  }
}
