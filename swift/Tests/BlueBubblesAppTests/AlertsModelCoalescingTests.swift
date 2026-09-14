//  AlertsModelCoalescingTests
//  The drawer honours the coalescing the alert centre does.
//
//  `AlertCenter` deliberately folds a repeated alert onto ONE row with an occurrence count --
//  "occurred 47 times", not 47 rows -- and broadcasts that same row on each recurrence. The
//  model inserted every broadcast, which undid that at the only place a person sees it and
//  grew `items` without bound for the life of the server: a flapping tunnel produced 47
//  identical rows in the drawer.
//
//  Each of those also fired the unread-count callback into `applyAppearance`, which asked
//  WindowServer to set an activation policy it was already set to.

import BBCore
import BBDiagnostics
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Alert drawer coalescing")
@MainActor
struct AlertsModelCoalescingTests {

  /// The same alert, raised repeatedly, as a flapping connection produces.
  private func repeatedAlert() -> UserAlert {
    UserAlert(
      severity: .warning,
      title: "The tunnel dropped",
      body: "Reconnecting",
      source: "test",
      dedupeKey: "proxy.flapping"
    )
  }

  @Test("A repeated alert stays one row")
  func repeatsCoalesce() async throws {
    let centre = AlertCenter()
    let model = AlertsModel()
    model.attach(centre)

    for _ in 0..<20 { await centre.raise(repeatedAlert()) }

    // The model follows a stream, so give it a moment to drain rather than assuming.
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.items.count == 1, "the drawer shows \(model.items.count) rows")
    #expect(model.items.first?.occurrenceCount == 20)
    // Non-vacuity: the centre really did see twenty raises, so one row is coalescing rather
    // than events being lost on the way.
    #expect(await centre.all(limit: 100).count == 1)
    #expect(await centre.all(limit: 100).first?.occurrenceCount == 20)
  }

  /// Two different alerts are two rows, or the fix above would be "show one alert, ever".
  @Test("Distinct alerts are still distinct rows")
  func distinctAlertsAreSeparate() async throws {
    let centre = AlertCenter()
    let model = AlertsModel()
    model.attach(centre)

    await centre.raise(
      UserAlert(severity: .warning, title: "One", body: "b", source: "test", dedupeKey: "a"))
    await centre.raise(
      UserAlert(severity: .warning, title: "Two", body: "b", source: "test", dedupeKey: "b"))
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.items.count == 2)
  }

  /// The unread count is re-read from the centre rather than incremented, which is what
  /// makes a recurrence of an already-counted alert not count twice.
  @Test("The unread count follows the centre rather than counting broadcasts")
  func unreadCountMatchesTheCentre() async throws {
    let centre = AlertCenter()
    let model = AlertsModel()
    model.attach(centre)

    for _ in 0..<5 { await centre.raise(repeatedAlert()) }
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.unreadCount == (await centre.badgeCount()))
    #expect(model.unreadCount <= 1, "five recurrences counted \(model.unreadCount) unread")
  }
}
