//  ConfigureSheet
//  A service's own configuration form, in a sheet.
//
//  Literally the same view the service's page shows, not a second copy of the fields: two
//  renderings of one manifest would drift, and the one nobody looks at would be the one that
//  is wrong. It was `private` to `ConnectionMethodRow` until the Notifications page needed
//  the identical sheet for ntfy, which is the point at which a shape gets standardised here
//  rather than copied.
//
//  The one thing that differs between the two callers is what sits ABOVE the form: a
//  connection method shows its published address there, because the sheet is where somebody
//  changes a field and watches for what it did. That is a generic `@ViewBuilder` slot with an
//  `EmptyView` default, the same shape `SettingsSection` uses for its trailing content and
//  for the same reason -- an `AnyView` would defeat SwiftUI's diffing and hide which views a
//  sheet can hold.

import BBServiceKit
import BBSettings
import SwiftUI

struct ConfigureSheet<Header: View>: View {
  let manifest: ServiceManifest
  let store: SettingsStore
  let model: AppModel
  let onDone: () -> Void
  private let header: Header

  init(
    manifest: ServiceManifest,
    store: SettingsStore,
    model: AppModel,
    onDone: @escaping () -> Void,
    @ViewBuilder header: () -> Header
  ) {
    self.manifest = manifest
    self.store = store
    self.model = model
    self.onDone = onDone
    self.header = header()
  }

  init(
    manifest: ServiceManifest,
    store: SettingsStore,
    model: AppModel,
    onDone: @escaping () -> Void
  ) where Header == EmptyView {
    self.init(manifest: manifest, store: store, model: model, onDone: onDone) { EmptyView() }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(manifest.name).font(.headline)
          Text(manifest.summary).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done", action: onDone).keyboardShortcut(.defaultAction)
      }
      .padding()

      Divider()
      // The form emits sections rather than a scrolling page, so the sheet supplies the
      // scrolling: the same content, laid out for a smaller frame.
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          ServiceFormView(manifest: manifest, store: store, model: model)
        }
        .padding(20)
      }
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 440, idealHeight: 560)
  }
}
