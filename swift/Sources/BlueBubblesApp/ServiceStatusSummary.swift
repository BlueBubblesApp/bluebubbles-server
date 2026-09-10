//  ServiceStatusSummary
//  What to say about a service that is switched on and is not running.
//
//  The Integrations screen showed no health at all: a service could be enabled, stranded
//  behind a dependency somebody switched off, failed on startup, or still coming up, and the
//  page would show a toggle sitting in the ON position and nothing else. That is the one
//  question the screen exists to answer (is this thing working) and it was the one thing it
//  did not say.
//
//  Only for a service that IS switched on. A switched-off one already says so with its
//  toggle, and repeating it as a status line would be the page arguing with itself.
//
//  Not a View, so the sentences can be asserted; touching a SwiftUI `View` type from a test
//  process traps. Same reason `AlertActionRouting` and `IntegrationCatalog` are their own
//  files.

import BBServiceKit

enum ServiceStatusSummary {

  /// One line about a service, and whether it reads as a problem.
  struct Line: Equatable {
    let text: String
    let symbol: String
    /// Orange rather than secondary. A service that is meant to be running and is not is
    /// worth noticing; one that is on its way up or waiting on something is not.
    let isProblem: Bool
  }

  /// What the screen should say, or nil when there is nothing worth saying.
  ///
  /// - Parameters:
  ///   - health: the registry's view, or nil when there is no server to ask.
  ///   - blockedBy: the name of a dependency this service needs that is switched off. The
  ///     registry knows only that one exists, because it deliberately does not put an
  ///     identifier in a sentence bound for a screen; the caller holds the manifests and
  ///     can name it.
  static func line(for health: ServiceHealth?, blockedBy: String? = nil) -> Line? {
    // No server, or a service the registry has never heard of. The page already says the
    // server is not running; a second sentence would be noise.
    guard let health else { return nil }

    switch health {
    // The good state says nothing. A row that reads "Running" on every service is a row
    // people stop reading, and then the one that says something else is missed too.
    case .running:
      return nil

    case .starting:
      return Line(text: "Starting…", symbol: "clock", isProblem: false)

    case .stopped:
      return Line(text: "Not running.", symbol: "pause.circle", isProblem: true)

    case .inactive(let reason):
      // The one inactive reason worth rewriting. The registry says only that A dependency
      // is off, because naming it would mean putting an identifier in the sentence; here
      // there are manifests in hand, so it can be named.
      if let blockedBy {
        return Line(
          text: "Waiting for \(blockedBy), which is switched off.",
          symbol: "arrow.triangle.branch",
          isProblem: true
        )
      }
      return Line(text: reason.capitalisedFirst + ".", symbol: "clock", isProblem: false)

    case .degraded(let reason):
      return Line(
        text: "Running, but \(reason).", symbol: "exclamationmark.circle", isProblem: true)

    case .failed(let reason):
      return Line(text: "Failed: \(reason)", symbol: "xmark.circle", isProblem: true)
    }
  }
}

extension String {
  /// The registry's reasons are written mid-sentence, so a line that leads with one needs
  /// its first letter lifted.
  var capitalisedFirst: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }
}
