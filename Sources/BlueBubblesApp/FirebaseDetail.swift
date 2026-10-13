//  FirebaseDetail
//  What the Firebase page can push on top of itself.
//
//  Registered devices used to be a sidebar row of its own, and it read the WRONG LIST: the
//  page called `TokenAuthService.devices()`, the token-auth enrolment registry, which under
//  `auth_mode = password` -- the default, and the only mode existing clients support --
//  constructs no registry at all and answers with an empty array. So a server with a phone
//  registered and delivering notifications showed "No devices. Devices appear here once a
//  client registers."
//
//  What a client actually registers is a push token, in the `device` table, and that table
//  is meaningless without Firebase: an FCM token is issued BY a project, every one of them
//  is dropped when the project changes, and with no credentials there is nothing to deliver
//  with. A page that can only ever be empty until Firebase is set up does not belong in the
//  sidebar beside pages that work on a default install. It belongs behind the thing it
//  depends on, which is where a person goes when they are thinking about notifications.
//
//  No raw value: the case is the identity and the title is a label, the same rule
//  `Destination`, `SettingsTab` and `LogLevelFilter` follow.

/// A page the Firebase screen pushes.
enum FirebaseDetail: Hashable, CaseIterable, Identifiable {
  case devices

  var id: Self { self }

  var title: String {
    switch self {
    case .devices: "Registered Devices"
    }
  }

  var symbol: String {
    switch self {
    case .devices: "iphone"
    }
  }
}
