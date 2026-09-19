//  FirebaseSummaryCard
//  The one-line answer at the top of the Firebase page: set up, half set up, not set up, or
//  unreadable, and the outcome of the last thing the user did, under it.
//
//  Push is OPTIONAL and this card says so first. A socket-only or webhook-only install is a
//  supported deployment that works perfectly, so the empty state is "not set up", not
//  "misconfigured", and there is no warning colour anywhere on it.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseSummaryCard: View {

  let setup: FirebaseSetupModel
  private var status: PushStatus? { setup.status }

  var body: some View {
    // `subhead` is the line that matters on an unconfigured server, and `.informational`
    // unless push is actually working is the reason this screen has no warning colour:
    // nothing here is broken. Not set up is a supported deployment.
    NoticeCard(
      symbol: headlineIcon,
      title: headline,
      tone: status?.isConfigured == true ? .good : .informational,
      messages: [subhead]
    ) {
      if let status, status.hasServiceAccount {
        HStack(spacing: 6) {
          if let projectId = status.projectId { Tag(projectId) }
          if let kind = status.databaseKind { Tag(kind) }
          Tag(status.registeredDevices.counted("device"))
        }
      }

      if let label = setup.activity.label {
        Text(label).font(.caption).foregroundStyle(.secondary)
      }
    } accessory: {
      if setup.isBusy { ProgressView().controlSize(.small) }
    }
  }

  private var headlineIcon: String {
    guard let status else { return "bell.slash" }
    if status.credentialProblem != nil { return "exclamationmark.triangle" }
    if status.isConfigured { return "bell.badge.fill" }
    return status.hasServiceAccount ? "exclamationmark.triangle" : "bell.slash"
  }

  private var headline: String {
    // Before the set-up branches: a credential that could not be READ is neither set up nor
    // not set up, and rendering it as the latter sends someone through setup to fix a
    // Keychain. See `PushStatus.credentialProblem`.
    if status?.credentialProblem != nil { return "Push credentials could not be read" }
    guard let status, status.hasServiceAccount || status.hasClientConfig else {
      return "Push notifications are not set up"
    }
    return status.isConfigured
      ? "Push notifications are set up"
      : "Push notifications are half set up"
  }

  private var subhead: String {
    guard let status else { return "" }
    if let problem = status.credentialProblem {
      return problem + " Unlock the Keychain or import the credentials again below."
    }
    if status.isConfigured {
      return "Clients receive messages while the app is closed."
    }
    // Naming the missing half, and what it costs, rather than reporting a configured
    // server. This state must not render as complete success.
    if status.hasServiceAccount {
      return """
        This server has a service account key but no google-services.json, so it can \
        send notifications but clients cannot fetch the Firebase configuration they \
        need in order to register for any. Add the missing file below.
        """
    }
    if status.hasClientConfig {
      return """
        This server has a google-services.json but no service account key, so it \
        cannot send notifications or publish its address. Add the missing file below.
        """
    }
    return """
      Optional. Without it, clients get messages over the socket while they are \
      connected, and webhooks and ntfy still work; only background delivery to a \
      closed app needs Firebase.
      """
  }
}

/// What the last action did, stated where the user is looking.
///
/// Carries a timestamp because several of these actions can legitimately report "nothing
/// needed changing", and a repeat of an identical result would otherwise be
/// indistinguishable from the button not working at all.
struct FirebaseOutcomeBanner: View {

  let outcome: FirebaseSetupModel.Outcome?

  var body: some View {
    if let outcome {
      GlassCard {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: outcome.symbol)
            .foregroundStyle(colour(for: outcome.kind))
          VStack(alignment: .leading, spacing: 2) {
            Text(outcome.text)
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
            Text(outcome.at.formatted(date: .omitted, time: .standard))
              .font(.caption).foregroundStyle(.tertiary)
          }
          Spacer(minLength: 0)
        }
      }
      // Keyed on identity, so a repeated action with the same text still animates and
      // therefore still reads as having happened.
      .id(outcome.id)
      .transition(.opacity)
    }
  }

  private func colour(for kind: FirebaseSetupModel.Outcome.Kind) -> Color {
    switch kind {
    case .success: .green
    case .info: .secondary
    case .failure: .red
    }
  }
}
