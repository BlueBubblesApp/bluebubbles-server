//  PrivateAPIStatusSummary
//  What the Private API status card says: whether the helper is actually answering, as
//  opposed to switched on.
//
//  Off the view so the four answers can be asserted; they were `private var`s on
//  `PrivateAPIStatusCard`. The distinction they draw is the whole reason the card exists:
//  injection quits and relaunches somebody else's app and waits for a helper inside it to
//  call back, any of which can fail or never finish while every switch on the page still
//  reads "on".

import BBPrivateAPI

struct PrivateAPIStatusSummary: Equatable {

  /// How the last start went, or nil when there is no server to ask.
  let outcome: PrivateAPIRuntime.StartOutcome?
  let isConnected: Bool

  var title: String {
    switch outcome {
    case .none, .notStarted: "Private API is not running"
    case .disabled: "Private API is switched off"
    case .running:
      isConnected ? "Private API is connected" : "Private API is waiting for the helper"
    case .timedOut: "Private API did not finish starting"
    case .failed: "Private API failed to start"
    }
  }

  var detail: String {
    switch outcome {
    case .none, .notStarted:
      "The server is not running, so nothing has been injected yet."
    case .disabled:
      "Turn on a switch below to inject the helper into that app."
    case .running:
      isConnected
        ? "The helper is injected and answering. Reactions, editing, unsending and typing "
          + "indicators are available."
        : "The helper was injected but has not called back yet. This is normal for a few "
          + "seconds after startup."
    case .timedOut:
      // Names the remedy, because the usual cause is the other app rather than this one.
      "Injection did not complete in time, so the server started without it. Everything "
        + "else works normally. Quitting and reopening Messages usually clears this."
    case .failed(let reason):
      reason
    }
  }

  var symbol: String {
    switch outcome {
    case .running: isConnected ? "checkmark.circle.fill" : "clock"
    case .timedOut, .failed: "exclamationmark.triangle.fill"
    case .none, .disabled, .notStarted: "circle.dashed"
    }
  }

  /// What each answer MEANS, rather than a colour: a helper still calling back is not a
  /// problem, and one that never will is.
  var tone: StatusTone {
    switch outcome {
    case .running: isConnected ? .good : .informational
    case .timedOut: .attention
    case .failed: .problem
    case .none, .disabled, .notStarted: .informational
    }
  }
}
