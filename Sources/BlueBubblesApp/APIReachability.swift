//  APIReachability
//  Whether the address this server publishes is one a client can actually connect to.
//
//  Home and Guides both answer "what do I type into the phone", and both answered it from
//  `server_address` alone. That setting is written by whichever connection method last
//  published, and NOTHING clears it when the listener stops, so switching the HTTP API off
//  left both pages showing a URL, a port and the sentence "This is the URL to enter in the
//  BlueBubbles app", for a server that refuses every connection. The address was true and
//  the page was wrong: the tunnel really did publish that name, and nothing is listening
//  behind it.
//
//  So the address is shown only when something is there to answer it, and the reason takes
//  its place when there is not. THREE reasons, because they lead to different next steps: the
//  server is not running at all, the listener is switched off, or the listener was asked to
//  start and could not.
//
//  That third case was the hole. This type's whole contract is "something is listening", and
//  the wiring below fed it the ENABLED SETTING, which is a different question. A service
//  whose `start()` throws does not abort the composition: `ServiceRegistry.startAll` records
//  it failed and hands it to a background supervisor. So with the HTTP API enabled and unable
//  to bind — a port already taken is the ordinary way — the phase was `.running`, this
//  answered `.reachable`, and Home showed a URL under "This is the URL to enter in the
//  BlueBubbles app" for a listener that never came up. Exactly the failure the paragraph
//  above describes, arriving through the one input that was never checked.
//
//  Not a View, so the sentences can be asserted; touching a SwiftUI `View` type from a test
//  process traps. Same reason `ServiceStatusSummary` and `IntegrationCatalog` are their own
//  files.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBBuiltIns
import BBServiceKit

enum APIReachability: Equatable {
  /// The listener is on. The address is worth showing and worth copying.
  case reachable
  /// The server itself is not running, so nothing has been published yet this launch.
  case serverStopped
  /// The server is running and the HTTP API is switched off. The socket goes with it, so
  /// this is every way a client has of reaching the server.
  case listenerSwitchedOff
  /// The HTTP API is switched ON and did not come up. A different sentence from the one
  /// above because it is a different next step: nothing to turn on, something to look at.
  case listenerFailed(reason: String)

  /// - Parameter listenerHealth: what the HTTP service reports about itself, or nil before
  ///   it has reported anything. Nil is treated as "not failed": during startup the service
  ///   has no health yet and the phase is not running, so `serverStopped` already covers it.
  static func of(
    isServerRunning: Bool,
    isListenerEnabled: Bool,
    listenerHealth: ServiceHealth?
  ) -> APIReachability {
    guard isServerRunning else { return .serverStopped }
    guard isListenerEnabled else { return .listenerSwitchedOff }
    switch listenerHealth {
    case .failed(let reason): return .listenerFailed(reason: reason)
    case .inactive(let reason): return .listenerFailed(reason: reason)
    // `.degraded` still answers requests, so the address is real. `.starting`, `.stopped`
    // and nil are all transient on a running server; claiming a failure for them would
    // flicker a warning during every start.
    default: return .reachable
    }
  }

  /// Whether a published address means anything right now.
  var showsAddress: Bool { self == .reachable }

  /// What stands in for the address, phrased as the next step rather than as a state.
  ///
  /// "Not set" would be wrong in every case: nobody sets this, the connection method
  /// publishes it, so the useful thing to say is which reason it is.
  var addressPlaceholder: String {
    switch self {
    case .reachable: "not published yet"
    case .serverStopped: "start the server to publish an address"
    case .listenerSwitchedOff: "the HTTP API is switched off"
    case .listenerFailed: "the HTTP API did not start"
    }
  }

  /// A sentence for the card, when there is something a person should know beyond the
  /// missing address. Nil when the page's ordinary explanation is still the right one.
  var note: String? {
    switch self {
    case .reachable, .serverStopped:
      nil
    case .listenerSwitchedOff:
      "The HTTP API is switched off, so this server is not accepting connections. "
        + "Turn it back on under Integrations to publish an address again."
    case .listenerFailed(let reason):
      "The HTTP API is switched on but did not start, so nothing is answering on this "
        + "address: \(reason)"
    }
  }
}

extension AppModel {

  /// Whether a client could connect right now, for the pages that show an address.
  var apiReachability: APIReachability {
    APIReachability.of(
      isServerRunning: phase.isRunning,
      // Read through the catalog like every other manifest lookup. Defaulting to enabled
      // when the manifest is somehow missing keeps a lookup failure from hiding an address
      // that is in fact serving.
      isListenerEnabled: IntegrationCatalog.manifest(BuiltInManifests.ID.http)
        .map { integrations.isEnabled($0) } ?? true,
      // What the service SAYS about itself, not what the switch says. A failed start leaves
      // the switch on and the phase running; this is the only input that can tell.
      listenerHealth: serviceHealths[BuiltInManifests.ID.http]
    )
  }
}
