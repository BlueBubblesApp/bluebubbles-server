//  AcceptedAndIgnoredTests
//  The requests this server used to accept and then quietly not honour.
//
//  Each of these was a 200 over a request that had been silently altered: an element dropped,
//  a field coerced, an index that could not survive the trip taken as zero. The project's own
//  rule is apply it or refuse it, and a `compactMap` is how the third option gets written by
//  accident — it reads as tolerance and behaves as data loss.
//
//  Where the reference refuses the same input, its sentence is transcribed, because a client
//  has been reading it. Where the route is v2 and there is nothing to transcribe, the wording
//  is ours and the rule is the same.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBEvents
import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Accepted and ignored")
struct AcceptedAndIgnoredTests {

  private func message(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as BadRequest {
      return error.errorMessage
    } catch {
      return String(describing: error)
    }
  }

  // MARK: Webhook events

  @Test("A webhook subscribing to events the server emits is created")
  func webhookEventsAccepted() throws {
    let events = try AdminHandlers.validatedEvents(
      .array([.string("new-message"), .string("updated-message")]))
    #expect(events == ["new-message", "updated-message"])
    #expect(try AdminHandlers.validatedEvents(.array([.string("*")])) == ["*"])
    // Absent means "leave it alone" on update and "everything" on create; both are the
    // caller's decision, not this function's.
    #expect(try AdminHandlers.validatedEvents(nil) == nil)
    #expect(try AdminHandlers.validatedEvents(.null) == nil)
  }

  /// The typo that created a webhook which never fired and never said why.
  @Test("An event name the server does not emit is refused, naming the set")
  func webhookEventTypo() {
    let text = message { _ = try AdminHandlers.validatedEvents(.array([.string("new-mesage")])) }
    #expect(text?.contains("Invalid webhook event: new-mesage!") == true)
    #expect(text?.contains("new-message") == true)
  }

  @Test("A non-string event is refused rather than dropped")
  func webhookEventNotAString() {
    let text = message {
      _ = try AdminHandlers.validatedEvents(.array([.string("new-message"), .int(7)]))
    }
    #expect(text == "Webhook events must be strings!")
  }

  @Test("Every event a webhook may subscribe to is one this server emits")
  func webhookCatalogAgrees() throws {
    let names = EventName.webhookSubscribable.map(\.rawValue)
    let accepted = try AdminHandlers.validatedEvents(.array(names.map(JSONValue.string)))
    #expect(accepted == names)
  }

  // MARK: Contact addresses

  @Test("A list of addresses is a query; nothing is a listing")
  func addressesAccepted() throws {
    #expect(
      try ReadHandlers.requestedAddresses(.array([.string("a@example.com")])) == ["a@example.com"])
    #expect(try ReadHandlers.requestedAddresses(nil) == [])
    #expect(try ReadHandlers.requestedAddresses(.null) == [])
    #expect(try ReadHandlers.requestedAddresses(.array([])) == [])
  }

  /// A bare string used to read as an empty list, and empty means "list everyone", so a
  /// client asking about one contact was answered with a page of all of them.
  @Test("A bare string where a list belongs is refused, in the reference's sentence")
  func addressesNotAList() {
    let text = message { _ = try ReadHandlers.requestedAddresses(.string("a@example.com")) }
    #expect(text == "Addresses must be an array of strings!")

    let mixed = message {
      _ = try ReadHandlers.requestedAddresses(.array([.string("a@example.com"), .int(2)]))
    }
    #expect(mixed == "Addresses must be an array of strings!")
  }

  // MARK: Poll options

  @Test("Poll options come through in order")
  func pollOptionsAccepted() throws {
    let options = try WriteHandlers.strings(
      .array([.string("Red"), .string("Blue")]), named: "options")
    #expect(options == ["Red", "Blue"])
    #expect(try WriteHandlers.strings(nil, named: "options") == [])
    // An empty `optionIds` is a vote retraction, which is a real request.
    #expect(try WriteHandlers.strings(.array([]), named: "optionIds") == [])
  }

  /// `["a", 2, "b"]` used to become a two-option poll, answered 200.
  @Test("A mistyped option is refused, and the index says which")
  func pollOptionMistyped() {
    let text = message {
      _ = try WriteHandlers.strings(
        .array([.string("Red"), .int(2), .string("Blue")]), named: "options")
    }
    #expect(text == "`options[1]` must be a string")
  }

  @Test("Options that are not a list at all are refused")
  func pollOptionsNotAList() {
    let text = message { _ = try WriteHandlers.strings(.string("Red,Blue"), named: "options") }
    #expect(text == "`options` must be an array of strings")
  }

  // MARK: partIndex

  private func values(_ object: [String: JSONValue]) -> RequestValues {
    RequestValues(.object(object))
  }

  @Test("An ordinary part index reads as itself, and an absent one as nothing")
  func partIndexAccepted() throws {
    #expect(try values(["partIndex": .int(0)]).wholeNumber("partIndex") == 0)
    #expect(try values(["partIndex": .int(3)]).wholeNumber("partIndex") == 3)
    #expect(try values([:]).wholeNumber("partIndex") == nil)
    #expect(try values(["partIndex": .null]).wholeNumber("partIndex") == nil)
  }

  /// The measured case: `9223372036854775807` reached the helper as the `Double` the wire
  /// carries, `WireJSON.intValue` answered nil, and the reaction was placed on part 0.
  @Test("An index that cannot survive the wire is refused rather than taken as zero")
  func partIndexOutOfRange() {
    let text = message {
      _ = try self.values(["partIndex": .int64(9_223_372_036_854_775_807)]).wholeNumber("partIndex")
    }
    #expect(text?.contains("`partIndex` must be a whole number") == true)
  }

  /// 2^53 is where a JSON number stops being able to carry consecutive integers, which is
  /// the real boundary; either side of it is checked so the rule is the round trip and not
  /// a magnitude somebody picked.
  @Test("The boundary is the round trip through a JSON number")
  func partIndexBoundary() throws {
    #expect(
      try values(["partIndex": .int64(9_007_199_254_740_992)]).wholeNumber("partIndex") != nil)
    #expect(
      message {
        _ = try self.values(["partIndex": .int64(9_007_199_254_740_993)]).wholeNumber("partIndex")
      } != nil)
  }

  /// A negative index is refused by the declarative layer before a handler sees it, so this
  /// accessor does not repeat the check; what it must not do is turn one into zero.
  @Test("A negative index is not silently floored")
  func partIndexNegative() throws {
    #expect(try values(["partIndex": .int(-1)]).wholeNumber("partIndex") == -1)
  }
}
