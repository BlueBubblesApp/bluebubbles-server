//  AlertCenterReporter
//  `AlertReporting` for a module, backed by the alert centre.
//
//  One struct, configured per module, replacing a bridge type per module. The source and the
//  dedupe key are the two things a caller could not know from inside its own module — where
//  the alert is filed, and whether a repeat should coalesce — so they are decided here.

import BBCore

public struct AlertCenterReporter: AlertReporting {

  private let center: AlertCenter
  private let source: String
  private let severity: Severity
  /// Nil raises a fresh alert each time. A fixed key coalesces repeats into one row with an
  /// occurrence count — right for a retry loop, wrong for a sequence of distinct events.
  private let dedupeKey: String?

  public init(
    center: AlertCenter, source: String, severity: Severity = .error, dedupeKey: String? = nil
  ) {
    self.center = center
    self.source = source
    self.severity = severity
    self.dedupeKey = dedupeKey
  }

  public func raise(title: String, detail: String) async {
    await center.raise(
      UserAlert(
        severity: severity, title: title, body: detail, source: source, dedupeKey: dedupeKey
      )
    )
  }
}
