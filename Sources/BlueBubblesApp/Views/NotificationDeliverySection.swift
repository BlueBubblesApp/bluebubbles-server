//  NotificationDeliverySection
//  The Notifications settings page: every way this server delivers an event, and the way
//  into each one's configuration.
//
//  Built from `NotificationDeliveryRouting`, which names the routes that deliver a
//  notification to a PERSON — not every event sink; see that file for why the two are not
//  the same question. What each row needs to say is the same three things for both: what the
//  route is, whether it is switched on, and whether it is actually configured — a sink that
//  is enabled and unconfigured is the state this project keeps finding, and the health line
//  is where it already answers that question.
//
//  The same shape `HTTPSettingsSection` has on the Connection page, which is what the
//  Notifications page was asked to look like: a section under the settings, with a Configure
//  button that opens the thing rather than reproducing it.

import BBServiceKit
import SwiftUI

struct NotificationDeliverySection: View {

  @Bindable var model: AppModel

  /// The route whose configuration sheet is open, if any.
  ///
  /// A wrapper because `ServiceManifest` is not `Identifiable` -- it is a plain value the
  /// host reads, and giving it an identity for a sheet's sake would be the view's needs
  /// leaking into the manifest model.
  private struct Configuring: Identifiable {
    let manifest: ServiceManifest
    var id: ServiceIdentifier { manifest.id }
  }

  @State private var configuring: Configuring?

  var body: some View {
    SettingsSection(
      "Delivery",
      subtitle: "How a notification reaches you when the client app is not open. These are "
        + "independent: either, both or neither can run, and a server with none of them "
        + "still delivers everything over the socket while a client is connected."
    ) {
      let routes = NotificationDeliveryRouting.routes
      DividedForEach(routes, id: \.id) { manifest in
        row(manifest)
      }
    }
    // The same sheet Configure ngrok opens, not a second rendering of the same manifest.
    .sheet(item: $configuring) { target in
      ConfigureSheet(manifest: target.manifest, model: model, onDone: { configuring = nil })
    }
  }

  private func row(_ manifest: ServiceManifest) -> some View {
    let isEnabled = model.integrations.isEnabled(manifest)
    // The status line says what it is DOING, when that is not simply running. An event sink
    // that is switched on and has nothing configured delivers nothing and looks identical to
    // one that is working, which is the whole reason the health line is on this row.
    return ManifestRow(
      manifest: manifest,
      isActive: isEnabled,
      status: isEnabled ? status(for: manifest) : nil
    ) {
      // Only when it is OFF. A row of "enabled" tags is a row people stop reading, at
      // which point the one that says something else is missed too — the same rule the
      // Integrations list follows about its status line.
      if !isEnabled { Tag("off") }
    } trailing: {
      configureButton(manifest)
    }
  }

  @ViewBuilder
  private func configureButton(_ manifest: ServiceManifest) -> some View {
    switch NotificationDeliveryRouting.destination(for: manifest) {
    case .page(let destination):
      // Named for where it goes, not "Configure": the button leaves this page, and a
      // person who presses it should not have to discover that by arriving somewhere else.
      Button("Open \(destination.title)") { model.selection = destination }
    case .configurationForm:
      Button("Configure \(manifest.name)") { configuring = Configuring(manifest: manifest) }
        // A form with no fields is an empty sheet. It cannot happen for anything shipped
        // today — `NotificationDeliveryRoutingTests` refuses it — and this is what a
        // third-party sink with an empty manifest would meet.
        .disabled(
          !model.settings.isAvailable
            || !NotificationDeliveryRouting.hasSomethingToConfigure(manifest))
    }
  }

  private func status(for manifest: ServiceManifest) -> ServiceStatusSummary.Line? {
    ServiceStatusSummary.line(
      for: model.serviceHealth(manifest.id),
      blockedBy: model.integrations.disabledDependency(of: manifest)?.name
    )
  }
}
