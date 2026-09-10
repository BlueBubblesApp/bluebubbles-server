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

    // ASKED OF THE APP'S OWN STATE, not read out of the registry's sentence. A method whose
    // dependency is switched off is stopped, not mid-restart, and it stays stopped until
    // that dependency is switched back on, so it belongs in no list of work in flight.
    //
    // The registry says the same thing in `inactive(reason:)`, but only as prose bound for
    // a screen, and deciding what a state IS by matching the words describing it is the
    // habit this app does not have. `disabledDependency` is the structural answer, and it
    // also names the dependency, which the registry deliberately will not.
    if let blocking = integrations.disabledDependency(of: manifest) {
      return .unavailable(method: name, reason: "\(blocking.name) is switched off")
    }

    switch health {
    case .running:
      return .connected(method: name)
    case .starting, .stopped:
      return .reconnecting(method: name, detail: "")
    case .inactive(let reason), .degraded(let reason):
      let routine = ["not started", "not connected", "disabled by configuration"]
      return .reconnecting(method: name, detail: routine.contains(reason) ? "" : reason)
    case .failed(let reason):
      return .failed(method: name, reason: reason)
    }
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
      await self?.syncPrivateAPIRuntime()
      for await snapshot in changes {
        self?.serviceHealths = snapshot
        await self?.syncPrivateAPIRuntime()
      }
    }
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
    webhookDeliveries = [:]
    accessControl = nil
    publishedAddress = ""
  }
}
