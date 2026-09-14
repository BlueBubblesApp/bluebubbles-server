//  PrivateAPIStatusCards
//  The two cards the Private API tab and the onboarding step share: the SIP prerequisite,
//  and whether the helper is actually answering.
//
//  Out of `SettingsView` because they are not settings rows and two screens draw them.

import BBPrivateAPI
import SwiftUI

/// The one prerequisite every Private API feature shares.
///
/// Placed above the sections rather than as help text on the first toggle, because it is not
/// advice about a setting; it is the reason none of them will do anything. The Permissions
/// page reports the live SIP state; this says what to do about it.
struct PrivateAPIPrerequisiteNote: View {

  var body: some View {
    NoticeCard(
      symbol: "exclamationmark.shield",
      title: "These features need System Integrity Protection disabled.",
      tone: .attention,
      messages: [
        "Everything on this page works by injecting a helper into Apple's apps, which "
          + "macOS blocks while SIP is on. The rest of the server (sending, receiving, "
          + "attachments) works normally without it."
      ]
    ) {
      Link(
        "Read the setup guide",
        destination: URL(string: "https://docs.bluebubbles.app/private-api/installation")!
      )
      .font(.callout)
    }
  }
}

/// Whether the Private API is actually working, as opposed to switched on.
///
/// Not the same thing as the toggle. Injection quits and relaunches somebody else's app and
/// waits for a helper inside it to call back; any of that can fail, or simply never finish,
/// while every toggle on the page still reads "on". The server bounds that wait and carries
/// on without it, which is the right behaviour and completely invisible unless something
/// says so here.
struct PrivateAPIStatusCard: View {

  let model: AppModel

  private var outcome: PrivateAPIRuntime.StartOutcome? { model.privateAPIState?.outcome }
  private var isConnected: Bool { model.privateAPIState?.isConnected ?? false }

  var body: some View {
    NoticeCard(symbol: symbol, title: title, tone: tone, messages: [detail])
  }

  private var title: String {
    switch outcome {
    case .none, .notStarted: "Private API is not running"
    case .disabled: "Private API is switched off"
    case .running:
      isConnected ? "Private API is connected" : "Private API is waiting for the helper"
    case .timedOut: "Private API did not finish starting"
    case .failed: "Private API failed to start"
    }
  }

  private var detail: String {
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

  private var symbol: String {
    switch outcome {
    case .running: isConnected ? "checkmark.circle.fill" : "clock"
    case .timedOut, .failed: "exclamationmark.triangle.fill"
    case .none, .disabled, .notStarted: "circle.dashed"
    }
  }

  /// The same four answers as before, said as what they MEAN rather than as a colour.
  ///
  /// A view choosing `.orange` decides twice (that this is worth noticing, and what
  /// noticing looks like) and only the first is its business. Named, the second answer is
  /// the same on every notice in the app.
  private var tone: NoticeTone {
    switch outcome {
    case .running: isConnected ? .good : .informational
    case .timedOut: .attention
    case .failed: .problem
    case .none, .disabled, .notStarted: .informational
    }
  }
}
