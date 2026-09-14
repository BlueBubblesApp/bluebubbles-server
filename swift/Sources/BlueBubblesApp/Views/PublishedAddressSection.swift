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
        // Read off the model, which follows `server_address` for the life of the server.
        // This page kept its own follower, which was the second of three for one key.
        CopyableValue(model.publishedAddress, placeholder: "Not published yet")
        if let state = stateLine {
          Label(state.text, systemImage: state.symbol)
            .font(.callout)
            .foregroundStyle(state.isProblem ? Color.orange : Color.secondary)
        }
      }
      .padding(.vertical, 4)
    }
  }

  private var isSelected: Bool { model.integrations.isEnabled(manifest) }

  /// One line on what the service is doing, so the address can be read in context.
  private var stateLine: (text: String, symbol: String, isProblem: Bool)? {
    guard isSelected else {
      return (
        "Not the selected connection method, so nothing is published from here.",
        "circle.dashed", false
      )
    }
    guard let health = model.serviceHealth(manifest.id) else { return nil }
    switch health {
    case .running: return ("Connected.", "checkmark.circle", false)
    case .starting: return ("Starting.", "clock", false)
    case .stopped: return ("Not running.", "pause.circle", true)
    case .inactive(let reason): return (reason.capitalisedFirst + ".", "clock", false)
    case .degraded(let reason): return ("Connected, but \(reason).", "exclamationmark.circle", true)
    case .failed(let reason): return ("Failed: \(reason).", "xmark.circle", true)
    }
  }

}
