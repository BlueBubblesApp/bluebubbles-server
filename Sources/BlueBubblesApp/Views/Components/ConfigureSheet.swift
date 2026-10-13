//  ConfigureSheet
//  A service's own configuration form, in a sheet.
//
//  Literally the same view the service's page shows, not a second copy of the fields: two
//  renderings of one manifest would drift, and the one nobody looks at would be the one that
//  is wrong. Shared by the connection method's row and the Notifications page, which opens
//  the identical sheet for ntfy.
//
//  The chrome is `SheetScaffold` with no Cancel: the form saves each field as it is edited,
//  so there is nothing held back for a Cancel to discard, and Done sits where every other
//  sheet commits.
//
//  The one thing that differs between the two callers is what sits ABOVE the form: a
//  connection method shows its published address there, because the sheet is where somebody
//  changes a field and watches for what it did. That is a generic `@ViewBuilder` slot with an
//  `EmptyView` default, the same shape `SettingsSection` uses for its trailing content and
//  for the same reason -- an `AnyView` would defeat SwiftUI's diffing and hide which views a
//  sheet can hold.
//
//  Done COMMITS before it closes. The form saves a text field on Return and on focus loss,
//  and clicking a button takes focus from nothing, so the field last typed in was the one a
//  Done left unsaved. The sheet asks the form to commit (`commitRequest`) and closes only
//  once everything landed: a refused field keeps the sheet open, with the refusal beside the
//  field, which is the one place it can be read.

import BBServiceKit
import SwiftUI

struct ConfigureSheet<Header: View>: View {
  let manifest: ServiceManifest
  let model: AppModel
  let onDone: () -> Void
  private let header: Header

  @State private var commitRequest = 0

  init(
    manifest: ServiceManifest,
    model: AppModel,
    onDone: @escaping () -> Void,
    @ViewBuilder header: () -> Header
  ) {
    self.manifest = manifest
    self.model = model
    self.onDone = onDone
    self.header = header()
  }

  init(
    manifest: ServiceManifest,
    model: AppModel,
    onDone: @escaping () -> Void
  ) where Header == EmptyView {
    self.init(manifest: manifest, model: model, onDone: onDone) { EmptyView() }
  }

  var body: some View {
    SheetScaffold(
      title: manifest.name,
      subtitle: manifest.summary,
      confirmTitle: "Done",
      cancel: .none,
      size: .detail,
      confirm: done
    ) {
      if model.settings.isAvailable {
        header
        // The form emits sections rather than a scrolling page, so the scaffold supplies the
        // scrolling: the same content, laid out for a smaller frame.
        ServiceFormView(
          manifest: manifest, model: model, commitRequest: commitRequest,
          onCommitted: onDone)
      } else {
        // The server stopped while the sheet was open: there is nothing to read the
        // fields from, and a form of blank fields would read as settings that are gone.
        ServerStoppedNotice(
          model: model, placement: .section(title: manifest.name),
          purpose: "change these settings")
      }
    }
  }

  /// Asks the form to commit, which closes the sheet once every field has landed. With no
  /// server there is nothing to commit, and the form is not on screen to answer the request.
  private func done() {
    if model.settings.isAvailable { commitRequest += 1 } else { onDone() }
  }
}
