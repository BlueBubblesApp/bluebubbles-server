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
//  **No door hands back the context itself.** The reference each facade holds is private, and
//  a door typed as a capability protocol returns a forwarder, never the `AppContext` as an
//  existential: `as? AppContext` on one would otherwise recover the whole container from a
//  door meant to open one thing. `AppModel` builds the facades; `FrontEndPlumbingPolicyTests`
//  refuses a door whose body is the bare context.
//
//  See `.claude/docs/architecture.md`.

import BBAppStore
import BBAudit
import BBAuth
import BBContacts
import BBFaceTime
import BBIMessage
import BBInterfaces
import BBLicense
import BBLicensing
import BBPrivateAPI
import BBPushKit
import BBShortcuts
import BBSystem
import BlueBubblesServerCore
import Foundation

/// Who may connect, how they prove it, and the certificate the server presents.
struct SecurityAccess {

  private let context: AppContext?

  init(context: AppContext?) { self.context = context }

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

  /// The audit table, as the repository rather than the recorder: the page reads and
  /// exports, and a read that throws is what `ScreenModel` needs to say it failed.
  var auditEvents: AuditRepository? { context?.auditEvents }

  /// Where the page hands in the one record it writes, the export. As the protocol rather
  /// than the actor, so a view cannot arm or disarm it.
  var auditRecorder: (any AuditRecording)? { context?.auditLog }
}

/// iMessage itself: reading it, sending through it, and whether the Private API is attached.
struct MessagingAccess {

  private let context: AppContext?

  init(context: AppContext?) { self.context = context }

  var contacts: ContactIndex? { context?.contacts }
  var scheduling: ScheduleInterface? { context?.schedule }
  var groupChatShortcuts: GroupChatShortcutManager? { context?.groupChatShortcuts }

  /// The Private API runtime the container holds now, resolved per read: the service that
  /// owns it publishes and withdraws it as it starts and stops.
  var privateAPIRuntime: PrivateAPIRuntime? {
    get async { await context?.privateAPIRuntime }
  }

  /// The message search index, for the row that reports on it.
  ///
  /// The STORE rather than the service: what the settings row needs is the state of the
  /// file, and the app has no business looking up a concrete service — the registry owns
  /// services, not the other way round. Rebuilding is a flag this sets and the indexer acts
  /// on, for the same reason.
  var searchIndex: SearchIndexStore? { context?.searchIndex }

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

  private let context: AppContext?

  init(context: AppContext?) { self.context = context }

  /// The runtime side of webhooks: delivery history and the test send. Registering and
  /// removing them is `AppModel.serverAdmin`, which is the same API a client uses.
  var webhooks: WebhookDirectory? { context?.webhooks }

  /// Firebase provisioning, as a capability rather than as the context it lives on.
  ///
  /// Handed to `FirebaseSetupModel`, which is the one part of the app with real signatures
  /// to constrain: it took `AppContext?` on twelve methods and used exactly this. A
  /// forwarder rather than the context, so the capability is all it is.
  var push: (any PushSetupProviding)? { context.map(PushSetup.init) }

  /// The registered push devices, as the table rather than as the delivery path's view of
  /// it.
  ///
  /// Deliberately NOT `DeviceDirectory`, which is the same table wearing the sender's
  /// failure policy: its methods swallow what goes wrong, because a notification must not
  /// fail because the device list could not be tidied. A screen needs the opposite -- a
  /// read that throws, so `ScreenModel` can say the read failed instead of drawing an empty
  /// list over it.
  var pushDevices: DeviceRepository? { context?.devices }
}

/// `PushSetupProviding` and nothing else. Private, so a cast cannot name it either.
private struct PushSetup: PushSetupProviding {
  let context: AppContext
  func pushInterface() async -> PushInterface { await context.pushInterface() }
}

/// This server's own subscription: what it is entitled to, and the two things a person does
/// about it.
///
/// A fourth GROUP rather than a fourth flat member on `AppModel`, which is what the rule in
/// `CLAUDE.md` asks for. It is not `security`: that group is about who may connect to this
/// server and how they prove it, and a subscription is about what this server has paid for.
/// Putting them together would make one group mean two things.
///
/// **There is no way to read the license key through this.** `LicenseRuntime` has no method
/// that returns one, on purpose: the key is a secret, and the page that sets it never needs to
/// read it back. See `LicenseStore`.
struct SubscriptionAccess {

  private let context: AppContext?

  init(context: AppContext?) { self.context = context }

  /// What this server is entitled to, right now. Cheap: an actor hop over a stored value.
  func report() async -> SubscriptionReport? {
    guard let context else { return nil }
    return SubscriptionReport(status: await context.license.status())
  }

  /// Exchanges the stored key for a fresh token, now, rather than waiting for the daily
  /// timer.
  ///
  /// A person pressing a button is not a poll. This is what makes entering a key feel like it
  /// did something: the service's schedule would otherwise get to it up to a day later.
  @discardableResult
  func refresh() async -> RefreshOutcome? {
    await context?.license.refresh()
  }

  /// Removes the license from this Mac.
  func remove() async throws {
    try await context?.license.clear()
  }
}

/// How the server has been doing: the history behind Home's charts.
///
/// A fifth GROUP, for the reason `SubscriptionAccess` is a fourth: none of the others is
/// about this. The LIVE numbers are not read through here; they arrive on `AppModel.metrics`
/// (a `MetricsModel`) from the server's own stream. This is the door for the reads a page makes on purpose: a
/// longer window than the hour the server keeps in memory, and the uptime timeline.
struct MonitoringAccess {

  private let context: AppContext?

  init(context: AppContext?) { self.context = context }

  var metrics: ServerMetrics? { context?.metrics }
}
