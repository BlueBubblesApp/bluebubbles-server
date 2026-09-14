//  HTTPSettingsPanel
//  Which settings the HTTP listener's own panel draws.
//
//  Two settings decide how the listener BINDS: the address it accepts connections on, and
//  whether it terminates TLS, and both used to sit loose in the Connection form between the
//  server's password and its published address. Read down that form and they look like two
//  more ways of reaching the server, alongside the connection method; they are not. They are
//  the HTTP service's configuration, and the only reason they were not under it is that they
//  are core settings rather than manifest fields.
//
//  So the panel is where they live now, reached from Configure HTTP Settings on the Connection
//  page, the same way a connection method's own fields are reached from Configure ngrok.
//
//  Declared HERE rather than as a `static` on the view, because touching a SwiftUI `View` type
//  from a test process traps and this list is exactly the thing worth a test: each of these is
//  marked `isInternal`, so the generated page no longer draws it, and a setting dropped from
//  this list would be one nothing draws at all.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBSettings

enum HTTPSettingsPanel {

  /// In the order the panel shows them: where it listens, then how it answers.
  static let settings: [AnySetting] = [
    Settings.bindAddress.erased,
    Settings.useCustomCertificate.erased,
  ]
}
