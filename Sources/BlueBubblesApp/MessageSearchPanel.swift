//  MessageSearchPanel
//  Which settings the Message Search section draws.
//
//  The switch used to sit in Features, between Startup Delay and Hide Dock Icon, with the
//  index's own state — a backfill still running, a count, Rebuild — in a second section
//  further down the same tab. Read down that page and the switch is one optional behaviour
//  among ten, and the thing it turns on is somewhere else. Somebody looking for it did not
//  find it.
//
//  So the switch and the state are one section, the same way the HTTP listener's settings
//  sit behind its own panel rather than loose in the Connection form.
//
//  Declared HERE rather than as a `static` on the view, because touching a SwiftUI `View`
//  type from a test process traps and this list is exactly the thing worth a test: it is
//  marked `isInternal`, so the generated page no longer draws it, and a setting dropped
//  from this list would be one nothing draws at all.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBSettings

enum MessageSearchPanel {

  static let settings: [AnySetting] = [
    Settings.searchIndexEnabled.erased
  ]
}
