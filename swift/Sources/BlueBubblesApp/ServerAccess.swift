//  ServerAccess
//  The doors from a SwiftUI view into the running server, grouped by what a screen is doing.
//
//  Each door is narrow: a screen that wants the tool manager gets the tool manager, not the
//  Keychain. They are grouped rather than listed flat on `AppModel`: a flat list on the model
//  every view holds grows by a line per server capability, and every screen then reads as
//  though it might touch any of them.
//
//  The doors are sorted into three groups. The point is
//  not access control: a view could always reach `server?.context` if it tried, and the
//  service layer is where real entitlements live. The point is that `AppModel` stops being the
//  place every new capability lands, and that a reader can see at a glance which part of the
//  server a screen is talking to.
//
//  Deliberately NOT protocol-typed the way a service's `Host` is. A service names
//  `any SettingsProviding & AlertProviding` and cannot see anything else, which works because
//  a service is constructed once with what it needs. A SwiftUI view is re-evaluated constantly
//  and reaches state through `@Observable`; putting that behind existentials would fight the
//  framework for a benefit that is organisational only. Grouping gets the readable half of
//  that idea without the fight.
//
//  Each of these is a struct built fresh on every access, holding one optional reference. Read
//  it, use it, let it go; do not store one across a view's lifetime, or it will be pointing at
//  a server that has since restarted.
//
//  See `.claude/docs/architecture.md`.

import BBAuth
import BBContacts
import BBFaceTime
import BBInterfaces
import BBPrivateAPI
import BBPushKit
import BBShortcuts
import BBSystem
import BlueBubblesServerCore
import Foundation

/// Who may connect, how they prove it, and the certificate the server presents.
struct SecurityAccess {

  fileprivate let context: AppContext?

  /// The blocklist, the allowlist and the rate limiter.
  var accessControl: AccessControlService? { context?.accessControl }

  /// Device tokens and enrolment. Constructs nothing under `auth_mode = password`, so this
  /// being present does not mean token auth is switched on.
  var tokenAuth: TokenAuthService? { context?.tokenAuth }

  /// TLS material, as a narrow collaborator rather than as the secret store.
  ///
  /// The rule the HTTP service follows: a screen that installs a certificate is handed
  /// something that can read and write TLS material and nothing else. Exposing
  /// `context.secrets` would give a settings view the whole Keychain.
  var certificates: CertificateKeychainStore? {
    context.map { CertificateKeychainStore(secrets: $0.secrets, logger: $0.logger) }
  }
}

/// iMessage itself: reading it, sending through it, and whether the Private API is attached.
struct MessagingAccess {

  fileprivate let context: AppContext?

  var contacts: ContactIndex? { context?.contacts }
  var scheduling: ScheduleInterface? { context?.schedule }
  var groupChatShortcuts: GroupChatShortcutManager? { context?.groupChatShortcuts }
  var privateAPI: (any PrivateAPIRuntimeProviding)? { context }

  var isHelperConnected: Bool {
    get async { await context?.isHelperConnected ?? false }
  }

  /// Resolved per call, all three, because what is behind them is replaced while the server
  /// runs; see `PrivateAPIProviding`. A stored copy would go on talking to a helper that
  /// has since been re-injected.
  func interfaces() async -> ServerInterfaces? { await context?.interfaces() }
  func faceTime() async -> FaceTimeCoordinator? { await context?.faceTime() }
  func ownMessagingAddress() async -> String? { await context?.ownMessagingAddress() }
}

/// How events leave the server: webhooks and push.
struct DeliveryAccess {

  fileprivate let context: AppContext?

  /// The runtime side of webhooks: delivery history and the test send. Registering and
  /// removing them is `AppModel.serverAdmin`, which is the same API a client uses.
  var webhooks: (any WebhookAdministering)? { context }

  /// Firebase provisioning, as a capability rather than as the context it lives on.
  ///
  /// Handed to `FirebaseSetupModel`, which is the one part of the app with real signatures
  /// to constrain: it took `AppContext?` on twelve methods and used exactly this.
  var push: (any PushSetupProviding)? { context }
}

extension AppModel {

  /// Constructed from the model's own context, which stays private, so the only way to a
  /// facade is through the model, and the only way to a context is through a facade.
  var security: SecurityAccess { SecurityAccess(context: serverContext) }
  var messaging: MessagingAccess { MessagingAccess(context: serverContext) }
  var delivery: DeliveryAccess { DeliveryAccess(context: serverContext) }
}
