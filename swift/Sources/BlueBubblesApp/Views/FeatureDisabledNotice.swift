//  FeatureDisabledNotice
//  What a page shows where a switched-off feature's controls would be.
//
//  A page that renders a feature's controls whether or not the feature is running is a page
//  that lies twice: it offers an action that will not take effect, and it hides the reason.
//  The API & Webhooks screen did this — you could register a webhook endpoint while Webhooks
//  was switched off in Integrations, and nothing on the screen said the endpoint would never
//  be called.
//
//  Its own view because there is more than one feature this can happen to, and because the
//  useful part is not the sentence — it is the way OUT of the state. Somewhere to turn it
//  back on has to be one click from where you noticed, or the notice is just a dead end that
//  reads slightly better than a lie.

import BBServiceKit
import SwiftUI

struct FeatureDisabledNotice: View {

  let manifest: ServiceManifest
  @Bindable var model: AppModel

  /// What the feature would be doing, phrased as what is NOT happening. "Webhooks are off"
  /// says less than "nothing is being POSTed to your endpoints".
  let consequence: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text("\(manifest.name) is turned off")
          .font(.body.weight(.medium))
      } icon: {
        Image(systemName: "pause.circle.fill")
          .foregroundStyle(.orange)
      }

      Text(consequence)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        // Turned back on from HERE, without a trip to another screen: the person
        // reading this is on this page because they wanted to use the feature.
        Button("Turn On \(manifest.name)") {
          Task { await model.toggle(manifest) }
        }
        .buttonStyle(.borderedProminent)

        // And a way to the full page anyway, for the permissions list and settings
        // that this notice deliberately does not reproduce.
        Button("Open Integration") { model.open(manifest.id) }
          .buttonStyle(.link)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
  }
}
