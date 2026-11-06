//  FeatureDisabledNotice
//  What a page shows where a switched-off feature's controls would be.
//
//  A page that renders a feature's controls whether or not the feature is running is a page
//  that lies twice: it offers an action that will not take effect, and it hides the reason.
//  The API & Webhooks screen did this: you could register a webhook endpoint while Webhooks
//  was switched off in Integrations, and nothing on the screen said the endpoint would never
//  be called.
//
//  Its own view because there is more than one feature this can happen to, and because the
//  useful part is not the sentence; it is the way OUT of the state. Somewhere to turn it
//  back on has to be one click from where you noticed, or the notice is just a dead end that
//  reads slightly better than a lie.
//
//  Three placements, the same idea as `ServerStoppedNotice`'s, because the pages are three
//  kinds: a page whose whole content is the feature (`.page`) stands in for all of it on a
//  `SettingsPage`; a page that otherwise renders gets a card of its own (`.card`); and a card
//  the page already draws, under its own heading, takes the bare block (`.inline`). The
//  placement is a required argument, so a page cannot wrap the notice in a `ScrollView` of its
//  own and bypass the layout every other page shares, which is what two pages did.

import BBServiceKit
import SwiftUI

struct FeatureDisabledNotice: View {

  enum Placement {
    /// The whole page, on a `SettingsPage`: the feature IS the page, so with it off there is
    /// nothing else to draw.
    case page
    /// A card of its own, above content that still renders.
    case card
    /// Inside a card the page draws, under that card's heading.
    case inline
  }

  let manifest: ServiceManifest
  @Bindable var model: AppModel
  let placement: Placement

  /// What the feature would be doing, phrased as what is NOT happening. "Webhooks are off"
  /// says less than "nothing is being POSTed to your endpoints".
  let consequence: String

  var body: some View {
    switch placement {
    case .page:
      SettingsPage {
        GlassCard { notice }
      }
    case .card:
      GlassCard { notice }
    case .inline:
      notice
    }
  }

  private var notice: some View {
    // `NoticeBody` rather than `NoticeCard`: the container changes with the placement. The
    // vocabulary is shared even though the container is not; this drew its own title at
    // `.body.weight(.medium)` where every other notice used `.headline`.
    NoticeBody(
      symbol: "pause.circle.fill",
      title: "\(manifest.name) is turned off",
      tone: .attention,
      messages: [consequence]
    ) {
      HStack(spacing: 12) {
        // Turned back on from HERE, without a trip to another screen: the person
        // reading this is on this page because they wanted to use the feature.
        Button("Turn On \(manifest.name)") {
          Task { await model.integrations.toggle(manifest) }
        }
        .buttonStyle(.borderedProminent)

        // And a way to the full page anyway, for the permissions list and settings
        // that this notice deliberately does not reproduce.
        Button("Open Integration") { model.open(manifest.id) }
          .buttonStyle(.link)
      }
      .padding(.top, 4)
    }
    .padding(.vertical, 2)
  }
}
