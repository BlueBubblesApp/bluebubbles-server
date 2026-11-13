//  PermissionsLiveUpdates
//  Declares that a view displays permission status, so the probe loop speeds up for it.
//
//  The probe loop has two cadences and the expensive one is worth paying only while someone
//  is reading the answer: a tick opens chat.db, spawns a thread for an XPC round trip to
//  `tccd`, and `dlopen`s a framework. Frontmost used to be the whole test, which meant the
//  dashboard and the log viewer paid it too.
//
//  Attached to the page rather than to `PermissionRow`, deliberately. A row is drawn once
//  per permission, so registering there would mean five tokens per page and five pushes per
//  appearance to say one thing.

import SwiftUI

extension View {
  /// Marks this view as one that renders permission status.
  ///
  /// While it is on screen AND the app is frontmost, the service re-probes every couple of
  /// seconds so a grant made in System Settings shows up without the user doing anything.
  /// Off screen, the service falls back to its idle cadence.
  func permissionsLiveUpdates(_ model: PermissionsModel) -> some View {
    modifier(PermissionsLiveUpdates(model: model))
  }
}

private struct PermissionsLiveUpdates: ViewModifier {

  let model: PermissionsModel

  /// This view's identity, for the whole time it is mounted.
  ///
  /// `@State` and not a computed UUID: a fresh one per body evaluation would register a new
  /// watcher on every redraw and deregister none of them.
  @State private var token = UUID()

  func body(content: Content) -> some View {
    content
      .onAppear { model.beginWatching(token) }
      .onDisappear { model.endWatching(token) }
  }
}
