//  PublishedAddressSection
//  The address a connection method is publishing, shown where the method is configured.
//
//  The point of every field on a tunnel's page is the URL that comes out the other end, and
//  the page did not show it. Someone changing a machine name, a port or a mode had to go to
//  Home to find out what it did, and the interesting moment, the few seconds while the
//  service restarts and republishes, was invisible from where they were sitting. This follows
//  `server_address` the way Home does, so the address changes under their eyes, and shows the
//  service's state beside it so a blank means "coming up" rather than "broken".

import BBBuiltIns
import BBServiceKit
import BBSettings
import SwiftUI

struct PublishedAddressSection: View {

  let manifest: ServiceManifest
  let model: AppModel

  var body: some View {
    SettingsSection(
      "Server Address",
      subtitle: "What clients connect to. It updates here as \(manifest.name) restarts and "
        + "republishes."
    ) {
      VStack(alignment: .leading, spacing: 8) {
        // Only for the method in use: the address on the model is what THAT method
        // published, and shown on another method's page it would read as this one's.
        if model.integrations.isEnabled(manifest) {
          ServerAddressRow(model: model, label: nil)
        }
        if let state = stateLine {
          ServiceStatusLine(state)
        }
      }
      .padding(.vertical, 4)
    }
  }

  /// One line on what the service is doing, so the address can be read in context. The
  /// sentences, and the choice between "Connected" and "Published", are
  /// `ServiceStatusSummary.publishedAddressLine`'s.
  ///
  /// `connectsToExternalService` is read off the manifest rather than inferred from whether
  /// the method runs a program; see `ServiceManifest.connectsToExternalService` for why that
  /// inference has already been got wrong here once.
  private var stateLine: ServiceStatusSummary.Line? {
    ServiceStatusSummary.publishedAddressLine(
      for: model.serviceHealth(manifest.id),
      isSelected: model.integrations.isEnabled(manifest),
      connectsToExternalService: manifest.connectsToExternalService)
  }
}
