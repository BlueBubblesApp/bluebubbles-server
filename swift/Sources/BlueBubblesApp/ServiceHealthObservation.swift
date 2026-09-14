//  ServiceHealthObservation
//  A service's state, as the registry sees it, for every row that shows one.
//
//  Followed from the registry's health stream for the life of the server, not polled and
//  not per view: the registry publishes a snapshot on every transition it performs, and a
//  service whose health moves on its own (a tunnel dropping, a helper connecting) reports
//  it. So a row shows a restart as it happens, and a row that is not on screen costs nothing
//  more than the one that is.

import BBServiceKit
import BlueBubblesServerCore
import Foundation

/// What the selected connection method is doing, for the indicator every page shows.
///
/// A connection method restarts whenever one of its settings changes and reconnects
/// whenever its tunnel drops, and both happen while the person is looking at some other
/// page. For the seconds it takes, every client is holding an address that is about to
/// change or has already stopped answering, which is worth a spinner in the corner
/// wherever they are, and worth naming, since "Reconnecting Tailscale: waiting for you
/// to sign in" is a different thing to do about than "Reconnecting Tailscale".
enum ConnectionActivity: Equatable {
  /// Connected and publishing. Nothing to show.
  case connected(method: String)
  /// Between addresses: stopping, starting, or waiting on something. `detail` is the
  /// registry's or the tunnel's own reason, empty when there is nothing more to say.
  case reconnecting(method: String, detail: String)
  /// Not running, and not going to be until somebody changes something.
  ///
  /// Distinct from `reconnecting` because the two ask opposite things of the person
  /// looking: one says wait, the other says this will not resolve on its own. Folded
  /// together, switching the HTTP API off left a spinner beside "Tailscale: a service it
  /// depends on is switched off" that never cleared, in a list whose whole promise is that
  /// it holds what is IN FLIGHT.
  case unavailable(method: String, reason: String)
  /// Gave up. The alert says why; this keeps it visible.
  case failed(method: String, reason: String)

  var method: String {
    switch self {
    case .connected(let method), .reconnecting(let method, _), .unavailable(let method, _),
      .failed(let method, _):
      method
    }
  }

  /// One line, for a tooltip or a status strip.
  var summary: String {
    switch self {
    case .connected(let method): "\(method) is connected"
    case .reconnecting(let method, let detail):
      detail.isEmpty ? "Reconnecting \(method)…" : "Reconnecting \(method): \(detail)"
    case .unavailable(let method, let reason): "\(method) is not running: \(reason)"
    case .failed(let method, let reason): "\(method) failed: \(reason)"
    }
  }

  var isInProgress: Bool {
    if case .reconnecting = self { return true }
    return false
  }
}

extension ConnectionActivity {

  /// What the selected connection method is doing, as a pure rule.
  ///
  /// Off the model because this mapping is the part that has been wrong twice and the model
  /// cannot be posed a question: `phase`, `selectedConnectionMethod` and `disabledServices`
  /// are all `private(set)`, so a test can reach this only if it does not need an `AppModel`.
  ///
  /// - Parameters:
  ///   - isSwitchedOff: this service's OWN switch, not `isEnabled`, which for an exclusive
  ///     category answers "is this the selected one" and is therefore true of the selected
  ///     method whatever its switch says.
  ///   - strandedBy: the name of a dependency that is switched off, if there is one.
  static func resolve(
    method: String,
    health: ServiceHealth,
    isSwitchedOff: Bool,
    strandedBy blocking: String?
  ) -> ConnectionActivity {
    // BOTH ASKED OF THE APP'S OWN STATE, not read out of the registry's sentence. A method
    // that is switched off, or stranded behind something that is, is stopped rather than
    // mid-restart, and stays stopped until somebody moves a switch, so neither belongs in a
    // list of work in flight.
    //
    // The registry says the same thing in `inactive(reason:)`, but only as prose bound for a
    // screen, and deciding what a state IS by matching the words describing it is the habit
    // this app does not have. It is also the habit that let the second of these through: the
    // dependency case was caught structurally while the service's own switch fell to the
    // `routine` list below, whose three strings do not include the registry's "switched
    // off". Switching off the selected method left "Tailscale — switched off" in the
    // background list, spinning, for as long as it stayed off.
    if let blocking {
      return .unavailable(method: method, reason: "\(blocking) is switched off")
    }
    if isSwitchedOff {
      return .unavailable(method: method, reason: "it is switched off")
    }

    switch health {
    case .running:
      return .connected(method: method)
    case .starting, .stopped:
      return .reconnecting(method: method, detail: "")
    case .inactive(let reason), .degraded(let reason):
      // The registry's own bookkeeping during a restart, which is genuinely in flight and
      // is not worth repeating at the person.
      let routine = ["not started", "not connected", "disabled by configuration"]
      return .reconnecting(method: method, detail: routine.contains(reason) ? "" : reason)
    case .failed(let reason):
      return .failed(method: method, reason: reason)
    }
  }
}

extension AppModel {

  func serviceHealth(_ id: ServiceIdentifier) -> ServiceHealth? { serviceHealths[id] }

  /// The selected connection method's state, or nil when there is no server to ask.
  ///
  /// Derived from the same followed health the Connection row reads, so the two never
  /// disagree. Reasons the registry uses for its own bookkeeping ("not started", "not
  /// connected") are the ordinary middle of a restart and are not repeated at the person;
  /// anything else is the tunnel explaining itself and is.
  var connectionActivity: ConnectionActivity? {
    guard phase == .running else { return nil }
    let selected = integrations.selectedConnectionMethod
    guard !selected.isEmpty,
      let manifest = IntegrationCatalog.manifest(ServiceIdentifier(selected)),
      let health = serviceHealths[manifest.id]
    else { return nil }
    let name = manifest.name

    return .resolve(
      method: name,
      health: health,
      isSwitchedOff: integrations.isSwitchedOff(manifest),
      strandedBy: integrations.disabledDependency(of: manifest)?.name
    )
  }

  /// Follows the registry's health for the life of the server.
  ///
  /// Subscribed before the seed read, so no transition can fall between them; the read is
  /// what puts the rows right on the first frame. Every snapshot also re-resolves the
  /// Private API runtime, because the service that owns it publishes and withdraws it as it
  /// starts and stops; see `syncPrivateAPIRuntime`.
  func followServiceHealth(_ registry: ServiceRegistry<AppContext>) {
    healthTask?.cancel()
    healthTask = Task { [weak self] in
      let changes = await registry.healthChanges()
      self?.serviceHealths = await registry.health()
      self?.noteStartupProgress()
      await self?.syncPrivateAPIRuntime()
      for await snapshot in changes {
        self?.serviceHealths = snapshot
        self?.noteStartupProgress()
        await self?.syncPrivateAPIRuntime()
      }
    }
  }

  /// Names the service the registry currently has in flight, while the server is coming up.
  ///
  /// Only while `startupStage` is already on that step: this follow runs for the whole life
  /// of the server, and a service restarting hours later because a setting changed is not
  /// the app starting. `ServiceHealth.starting` is the registry's own `startsInFlight`, so
  /// this reads a structural fact rather than a sentence; see `StartupStage`.
  private func noteStartupProgress() {
    guard case .startingServices = startupStage else { return }
    let inFlight =
      serviceHealths
      .filter { $0.value == .starting }
      .keys
      // Sorted so two services starting at once (nothing forbids it) do not make the label
      // flicker between them on every snapshot.
      .sorted { $0.rawValue < $1.rawValue }
      .first
    setStartupStage(.startingServices(name: inFlight.map(IntegrationCatalog.name(of:))))
  }

  /// Stops every follow and clears what it held, so a stopped server shows nothing stale.
  func stopFollowingServer() {
    healthTask?.cancel()
    healthTask = nil
    toolsTask?.cancel()
    toolsTask = nil
    privateAPITask?.cancel()
    privateAPITask = nil
    followedPrivateAPIRuntime = nil
    logTask?.cancel()
    logTask = nil
    webhookDeliveriesTask?.cancel()
    webhookDeliveriesTask = nil
    webhookRegistrationsTask?.cancel()
    webhookRegistrationsTask = nil
    accessControlTask?.cancel()
    accessControlTask = nil
    addressTask?.cancel()
    addressTask = nil
    serviceHealths = [:]
    toolStatuses = [:]
    privateAPIState = nil
    logLines = []
    logFileURL = nil
    logSink = nil
    webhookDeliveries = [:]
    accessControl = nil
    publishedAddress = ""
  }
}
