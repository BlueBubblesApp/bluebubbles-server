//  FaceTimeBridge+Alerts
//  The UI FaceTime puts up when a dial wedges. The Private API says nothing about it, so it
//  is read and dismissed through AppKit, and dismissal always cancels, never confirms.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import AppKit

extension FaceTimeBridge {

  // MARK: - Blocking alerts

  /// What FaceTime.app is showing, for diagnosing a wedged dial.
  ///
  /// Dialling an address that is not FaceTime-capable does not fail the API call: a
  /// `TUCall` is created and reports `outgoing`, but FaceTime puts up "…is not available
  /// for FaceTime" and the call never forms a conversation. The alert is a UI object the
  /// private API says nothing about, so it is inspected through AppKit.
  @MainActor
  static func windowSummaries() -> [String] {
    NSApplication.shared.windows.map { window in
      let sheet = window.attachedSheet.map { " attachedSheet=\(type(of: $0))" } ?? ""
      return "\(type(of: window)) title=\(window.title.isEmpty ? "-" : window.title) "
        + "visible=\(window.isVisible) sheet=\(window.isSheet) "
        + "level=\(window.level.rawValue)\(sheet)"
    }
  }

  /// Dismisses a blocking alert, CANCELLING rather than confirming.
  ///
  /// Deliberately the safe button: this alert's other options offer to call a DIFFERENT
  /// address on the contact card, and dismissing it by confirming could place a call to
  /// someone the client never asked for. Cancelling only ever un-wedges the app.
  ///
  /// Returns how many were dismissed, so a caller can tell "cleared a blockage" from
  /// "nothing was blocking".
  @MainActor
  static func dismissBlockingAlerts() -> Int {
    var dismissed = 0
    let app = NSApplication.shared

    // App-modal alert: end the modal session, then close the window it ran.
    if let modal = app.modalWindow {
      app.abortModal()
      modal.close()
      dismissed += 1
    }
    // Sheet on any window: end it with a cancel response.
    for window in app.windows {
      guard let sheet = window.attachedSheet else { continue }
      window.endSheet(sheet, returnCode: .cancel)
      dismissed += 1
    }
    return dismissed
  }
}
