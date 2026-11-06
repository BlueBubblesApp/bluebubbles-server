//  PrivateAPIStatusCards
//  The two cards the Private API tab and the onboarding step share: the SIP prerequisite,
//  and whether the helper is actually answering.
//
//  Out of `SettingsView` because they are not settings rows and two screens draw them.

import SwiftUI

/// The one prerequisite every Private API feature shares.
///
/// Placed above the sections rather than as help text on the first toggle, because it is not
/// advice about a setting; it is the reason they will or will not do anything. What it says
/// is `PrivateAPIPrerequisite`, from the same read the Permissions tab draws, which also
/// says why there is nothing here to re-check.
struct PrivateAPIPrerequisiteNote: View {

  let prerequisite: PrivateAPIPrerequisite

  var body: some View {
    NoticeCard(
      symbol: prerequisite.symbol,
      title: prerequisite.title,
      tone: prerequisite.tone,
      messages: [prerequisite.detail]
    ) {
      if prerequisite.showsSetupGuide {
        Link(
          "Read the setup guide",
          destination: URL(string: "https://docs.bluebubbles.app/private-api/installation")!
        )
        .font(.callout)
      }
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

  var body: some View {
    let summary = PrivateAPIStatusSummary(
      outcome: model.privateAPIState?.outcome,
      isConnected: model.privateAPIState?.isConnected ?? false)
    NoticeCard(
      symbol: summary.symbol, title: summary.title, tone: summary.tone,
      messages: [summary.detail])
  }
}
