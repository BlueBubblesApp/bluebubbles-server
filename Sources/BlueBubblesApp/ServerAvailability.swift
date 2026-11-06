//  ServerAvailability
//  What a page says where its content would be, while there is no running server to read
//  it from.
//
//  Two different things can be true while the server is not running, and a page can show
//  both at once. The settings door (`model.settings`) is attached BEFORE the start delay, so
//  the settings screen opens while the server waits to start, and a tab can draw live setting
//  rows; the sections under them that need the running server (access control, the archive)
//  cannot. The sentence under those rows is the one decided here, from the phase, so it
//  says the server is on its way up during a start rather than "not running" under rows
//  that plainly work.
//
//  Not a View, so the sentences can be asserted; touching a SwiftUI `View` type from a test
//  process traps.

import Foundation

extension ServerPhase {

  /// Whether the server is on its way up, so a page should say "starting" rather than
  /// offer a Start button that would do nothing.
  var isComingUp: Bool {
    switch self {
    case .starting, .waiting: true
    case .idle, .running, .stopping, .failed, .migrationRequired: false
    }
  }

  /// The headline a page shows in place of content that needs the running server.
  var unavailableHeadline: String {
    switch self {
    case .starting, .waiting: "Server starting"
    case .stopping: "Server stopping"
    case .idle, .running, .failed, .migrationRequired: "Server not running"
    }
  }

  /// The sentence under it, ending in what the page is for: "view contacts".
  func unavailableExplanation(purpose: String) -> String {
    switch self {
    case .starting, .waiting: "This fills in once the server is up, to \(purpose)."
    case .stopping: "Start the server again to \(purpose)."
    case .idle, .running, .failed, .migrationRequired: "Start the server to \(purpose)."
    }
  }

  /// What a section says in its body, where the explanation is its subtitle.
  var unavailableDetail: String {
    switch self {
    case .starting, .waiting: "The server is starting, so there is nothing to show yet."
    case .stopping: "The server is stopping."
    case .idle, .running, .failed, .migrationRequired:
      "The server is not running, so there is nothing to show yet."
    }
  }
}
