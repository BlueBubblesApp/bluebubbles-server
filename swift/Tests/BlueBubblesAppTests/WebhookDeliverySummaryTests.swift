//  WebhookDeliverySummaryTests
//  What the Webhooks page says about an endpoint's last delivery.
//
//  The matching rule is the one worth having under test, and it is not obvious from reading
//  the row: an outcome is claimed only when the URL matches as well as the id, because
//  SQLite REUSES row ids after a delete. Without it, a deleted endpoint's failure is shown
//  against whichever new endpoint inherits its id.

import BBEvents
import BBInterfaces
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Webhook delivery summary")
struct WebhookDeliverySummaryTests {

  private func webhook(id: Int64?, url: String) throws -> Webhook {
    let created = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate
    let idField = id.map { "\"id\": \($0)," } ?? ""
    let json = """
      {\(idField) "url": "\(url)", "events": "[\\"*\\"]", "created_at": \(created)}
      """
    return try JSONDecoder().decode(Webhook.self, from: Data(json.utf8))
  }

  private func state(
    url: String, outcome: WebhookDeliveryState.Outcome = .delivered, failures: Int = 0
  ) -> WebhookDeliveryState {
    WebhookDeliveryState(
      outcome: outcome, at: Date(timeIntervalSince1970: 1_800_000_000),
      consecutiveFailures: failures, event: "new-message", url: url)
  }

  // MARK: - Matching

  @Test("An outcome recorded for this endpoint is shown against it")
  func matchingOutcome() throws {
    let hook = try webhook(id: 1, url: "https://example.com/hook")
    let tracked = [Int64(1): state(url: "https://example.com/hook")]
    #expect(WebhookDeliverySummary.delivery(for: hook, in: tracked) != nil)
  }

  /// **The id-reuse rule.** SQLite hands a deleted row's id to the next insert, so an id
  /// match alone would show the old endpoint's failure against the new one.
  @Test("An outcome whose URL does not match is not claimed, however the ids line up")
  func idReuseIsNotEnough() throws {
    let replacement = try webhook(id: 1, url: "https://new.example.com/hook")
    let stale = [
      Int64(1): state(
        url: "https://old.example.com/hook", outcome: .failed("HTTP 404"), failures: 5)
    ]
    #expect(WebhookDeliverySummary.delivery(for: replacement, in: stale) == nil)
  }

  @Test("An unsaved endpoint owns no outcome")
  func noIdNoOutcome() throws {
    let unsaved = try webhook(id: nil, url: "https://example.com/hook")
    let tracked = [Int64(1): state(url: "https://example.com/hook")]
    #expect(WebhookDeliverySummary.delivery(for: unsaved, in: tracked) == nil)
  }

  @Test("Nothing tracked means nothing shown")
  func nothingTracked() throws {
    let hook = try webhook(id: 1, url: "https://example.com/hook")
    #expect(WebhookDeliverySummary.delivery(for: hook, in: [:]) == nil)
  }

  // MARK: - The sentence

  @Test("A delivery says it was delivered, and names no streak")
  func describesDelivery() {
    let line = WebhookDeliverySummary.describe(state(url: "https://example.com/hook"))
    #expect(line.hasPrefix("Delivered "))
    #expect(!line.contains("in a row"))
  }

  @Test("A failure names the reason")
  func describesFailure() {
    let line = WebhookDeliverySummary.describe(
      state(url: "https://example.com/hook", outcome: .failed("HTTP 404"), failures: 1))
    #expect(line.hasPrefix("Failed "))
    #expect(line.contains("HTTP 404"))
  }

  /// The streak separates "the endpoint blipped" from "this has been dead all afternoon".
  /// Suppressed at one, because "1 in a row" is not a streak and reads as a bug.
  @Test("A streak is named from two failures, never from one")
  func streakThreshold() {
    let once = WebhookDeliverySummary.describe(
      state(url: "https://example.com/hook", outcome: .failed("HTTP 500"), failures: 1))
    #expect(!once.contains("in a row"))

    let repeated = WebhookDeliverySummary.describe(
      state(url: "https://example.com/hook", outcome: .failed("HTTP 500"), failures: 7))
    #expect(repeated.contains("7 in a row"))
  }
}
