//  RecordingAlerts
//  What would have reached the notification drawer, kept for a test to read.
//
//  Five copies of this existed under three names, and they disagreed about the one thing an
//  alert test asserts on. Two kept an error as the alert it derives; one kept errors and
//  alerts in separate lists; two dropped errors entirely, so code that raised one looked to
//  its test as if it had raised nothing. This keeps both views: every raise as the alert the
//  drawer would show, and the errors as themselves, so a test can match on the type.

import BBCore
import BBDiagnostics

public actor RecordingAlerts: AlertRaising {

  /// Everything raised, in order, an error as the alert it derives.
  public private(set) var alerts: [UserAlert] = []

  /// The errors raised as errors, in order.
  public private(set) var errors: [any BBError] = []

  public init() {}

  public func raise(_ alert: UserAlert) async { alerts.append(alert) }

  public func raise(_ error: any BBError, actions: [AlertAction]) async {
    errors.append(error)
    alerts.append(UserAlert(error, actions: actions))
  }

  /// The alerts' titles, in order.
  public var titles: [String] { alerts.map(\.title) }

  /// Waits until at least `count` errors have been raised, and returns them all.
  ///
  /// For code that raises from an unstructured `Task`, where nothing tells the caller the
  /// raise has landed.
  ///
  /// - Throws: `WaitTimedOut` if fewer than `count` arrive in time.
  public func waitForErrors(
    _ count: Int, timeout: Duration = .seconds(5)
  ) async throws -> [any BBError] {
    try await waitFor("\(count) raised errors", timeout: timeout) {
      errors.count >= count ? errors : nil
    }
  }
}
