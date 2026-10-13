//  HomeConnectionCard
//  How clients reach this server.
//
//  On Home rather than only on Guides because it is the answer to the question people open
//  this app to ask. The Guides page and a read-only settings row are not where someone looks
//  after starting the server.
//
//  Reads nothing itself. The method is `IntegrationsModel`'s, and the address and port are
//  the model's followed `clientAddress`, so the card moves when a tunnel republishes while the
//  page is open, the same moment every other place showing the address moves.

import BBServiceKit
import SwiftUI

struct HomeConnectionCard: View {

  @Bindable var model: AppModel

  /// The method's own name, from its manifest: "Cloudflare Tunnel", "Local Network". Falls
  /// back to the raw identifier, which is the honest answer for a method this build does not
  /// have installed, and to `-` with no server.
  private var method: String {
    let selected = model.integrations.selectedConnectionMethod
    guard !selected.isEmpty else { return "-" }
    return IntegrationCatalog.manifest(ServiceIdentifier(selected))?.name ?? selected
  }

  var body: some View {
    HomeCard(
      "Connection", symbol: "network",
      // Straight to the tab that owns the method picker, not to Settings' first tab.
      destination: ("Change", { model.openSettings(tab: .connection) })
    ) {
      // The method as a tag, matching how Guides tags the Private API state: it is a fixed
      // piece of vocabulary rather than a sentence, and it is the context that makes the
      // address below make sense.
      Tag(method)

      ServerAddressRow(model: model)
      LabeledContent("Local port", value: model.clientAddress.port.map(String.init) ?? "-")

      // The reachability note replaces this sentence rather than sitting beside it: with
      // nothing listening, "the URL to enter" is an instruction to type a dead address.
      if model.apiReachability.note == nil {
        Text("This is the URL to enter in the BlueBubbles app, with your server password.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
