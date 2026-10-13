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

  /// One line about a service, and the tone it is drawn in.
  struct Line: Equatable {
    let text: String
    let symbol: String
    /// `.attention` for a service that is meant to be running and is not, which is worth
    /// noticing; `.informational` for one on its way up or waiting on something, which is
    /// not. A list line never says `.problem`: red is kept for the notices that report
    /// something broken until somebody acts, and a registry that is retrying a service is
    /// still acting.
    let tone: StatusTone

    /// Whether the line is worth noticing.
    var isProblem: Bool { tone == .attention || tone == .problem }
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
      return Line(text: "Starting…", symbol: "clock", tone: .informational)

    case .stopped:
      return Line(text: "Not running.", symbol: "pause.circle", tone: .attention)

    case .inactive(let reason):
      // The one inactive reason worth rewriting. The registry says only that A dependency
      // is off, because naming it would mean putting an identifier in the sentence; here
      // there are manifests in hand, so it can be named.
      if let blockedBy {
        return Line(
          text: "Waiting for \(blockedBy), which is switched off.",
          symbol: "arrow.triangle.branch",
          tone: .attention
        )
      }
      return Line(text: reason.capitalisedFirst + ".", symbol: "clock", tone: .informational)

    case .degraded(let reason, _):
      return Line(
        text: "Running, but \(reason).", symbol: "exclamationmark.circle", tone: .attention)

    case .failed(let reason):
      return Line(text: "Failed: \(reason)", symbol: "xmark.circle", tone: .attention)
    }
  }

  /// The line under a connection method's published address.
  ///
  /// Differs from `line(for:blockedBy:)` in two ways, both because it sits beside an
  /// address rather than in a list. It says something when the method is running, because
  /// a blank under an empty address reads as broken rather than as "coming up"; and it says
  /// something for a method that is not the selected one, because that page still shows the
  /// address field, and nothing explains why it is empty.
  ///
  /// - Parameters:
  ///   - health: the registry's view, or nil when there is no server to ask.
  ///   - isSelected: whether this is the connection method in use.
  ///   - connectsToExternalService: `ServiceManifest.connectsToExternalService`, which picks
  ///     the word for working. "Connected" is true of a tunnel, which holds a session open
  ///     with somebody else's infrastructure; a Local Network or Custom URL method opens no
  ///     session with anything and only publishes an address, so it says "Published".
  static func publishedAddressLine(
    for health: ServiceHealth?, isSelected: Bool, connectsToExternalService: Bool
  ) -> Line? {
    guard isSelected else {
      return Line(
        text: "Not the selected connection method, so nothing is published from here.",
        symbol: "circle.dashed", tone: .informational)
    }
    guard let health else { return nil }
    let working = connectsToExternalService ? "Connected" : "Published"
    switch health {
    case .running:
      return Line(text: working + ".", symbol: "checkmark.circle", tone: .informational)
    case .starting:
      return Line(text: "Starting.", symbol: "clock", tone: .informational)
    case .stopped:
      return Line(text: "Not running.", symbol: "pause.circle", tone: .attention)
    case .inactive(let reason):
      return Line(text: reason.capitalisedFirst + ".", symbol: "clock", tone: .informational)
    case .degraded(let reason, _):
      return Line(
        text: "\(working), but \(reason).", symbol: "exclamationmark.circle", tone: .attention)
    case .failed(let reason):
      return Line(text: "Failed: \(reason).", symbol: "xmark.circle", tone: .attention)
    }
  }

  /// The line under the connection-method picker: what the CHOSEN method is doing.
  ///
  /// Differs from `line(for:blockedBy:)` in two ways, both because it is the only status the
  /// Connection page shows for the method. It speaks in every state, since a silent row
  /// under a picker reads as unknown rather than as fine; and it names the method, because
  /// the picker's value can change under the sentence. A failed method is `.problem`: it is
  /// the one thing on that page that decides whether any client can connect.
  ///
  /// - Parameters:
  ///   - health: the registry's view, or nil when there is no server to ask.
  ///   - name: the method's name, from its manifest.
  ///   - blockedBy: the name of a dependency it needs that is switched off. Checked before
  ///     the health, which reports that case as `inactive`: a clock and an informational
  ///     tone, the vocabulary of waiting, for a state that resolves only when somebody turns
  ///     the dependency back on.
  static func connectionMethodLine(
    for health: ServiceHealth?, name: String, blockedBy: String? = nil
  ) -> Line? {
    guard let health else { return nil }
    if let blockedBy {
      return Line(
        text: "\(name) is not running: \(blockedBy) is switched off.",
        symbol: "pause.circle", tone: .attention)
    }
    switch health {
    case .running:
      return Line(text: "\(name) is connected.", symbol: "checkmark.circle", tone: .informational)
    case .starting:
      return Line(text: "\(name) is starting.", symbol: "clock", tone: .informational)
    case .stopped:
      return Line(text: "\(name) is not running.", symbol: "pause.circle", tone: .attention)
    case .inactive(let reason):
      return Line(text: "\(name): \(reason).", symbol: "clock", tone: .informational)
    case .degraded(let reason, _):
      return Line(
        text: "\(name) is connected but \(reason).", symbol: "exclamationmark.circle",
        tone: .attention)
    case .failed(let reason):
      return Line(text: "\(name) failed: \(reason).", symbol: "xmark.circle", tone: .problem)
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
