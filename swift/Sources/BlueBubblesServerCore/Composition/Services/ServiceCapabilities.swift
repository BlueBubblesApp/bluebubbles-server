//  ServiceCapabilities
//  The capabilities only a service composes.
//
//  `BBInterfaces/Capabilities.swift` holds the protocols the handlers, the composition root
//  and the SwiftUI app share, and `BBHandlers/HandlerCapabilities.swift` holds the ones only
//  a handler composes. These are the third case, and they are INTERNAL — unlike the handler
//  capabilities, whose composers are in another module, nothing outside this one declares or
//  satisfies these.
//
//  That is load-bearing for the second group below. Publishing a runtime into the container
//  is a service's privilege and nobody else's: a handler that could hand the container a
//  Private API client, or withdraw the one that is there, would be a bug that type-checks.
//  Keeping these protocols internal to this module means a handler cannot even name them.
//
//  The first group is here for a duller reason: naming `ToolManager` or `EngineIOServer`
//  from the domain layer would make it depend on the tool downloader and the socket
//  transport in order to declare two protocols nothing in it uses.
//
//  See `.claude/docs/architecture.md`.

import BBAuth
import BBContacts
import BBPrivateAPI
import BBPrivateAPIContract
import BBPushKit
import BBSocketIO
import BBTooling

// MARK: - Subsystems the domain layer does not know about

/// The managed external programs — ngrok, cloudflared, zrok.
protocol ToolProviding: Sendable {
  var tools: ToolManager { get }
}

/// When a client was last heard from.
///
/// The tracker lives in this module, so this capability could not be declared anywhere else
/// even if another layer wanted it.
protocol ClientActivityProviding: Sendable {
  var clientActivity: ClientActivityTracker { get }
}

/// The Socket.IO transport: the client registry and the Engine.IO layer under it.
///
/// One capability rather than two because nothing holds one without the other — the sink
/// writes to the server and the maintenance loop runs on the engine, and a service that
/// starts one and not the other has half a transport.
protocol SocketRuntimeProviding: Sendable {
  var socketServer: SocketServer { get }
  var engineIO: EngineIOServer { get }
}

// MARK: - Publishing a runtime into the container

//  These three are the direction the capability model did not previously describe. A service
//  is not only a consumer of the container: three of them CONSTRUCT something while they run
//  — the Private API client, the push service, the contacts ingestor — and hand it over so
//  that handlers, the app and `interfaces()` can reach it. `AppContext.PublishedRuntime` is
//  where it lands, and its `didSet` is what invalidates the cached interfaces.
//
//  Every one is `async` because the container is an actor and these are isolated members.
//  A publish and its withdrawal are one protocol, never two: a service that can hand
//  something over has to be the thing that takes it back, and splitting them would let a
//  service take away what it never supplied.

/// Handing over the address-book ingestor the contact interface refreshes through.
///
/// There is no withdrawal: the ingestor holds no connection and outliving its service is
/// harmless, where a stale Private API client is not.
protocol ContactsIngestorPublishing: Sendable {
  func publish(contactsIngestor: ContactsIngestor) async
}

/// Handing over the push service so `PushInterface` drives setup against the SAME instance
/// the sink delivers through.
protocol PushDeliveryPublishing: Sendable {
  func publish(pushDelivery: PushService) async
  func withdrawPushDelivery() async
}

/// Handing over the Private API client and the runtime that injected it.
///
/// The withdrawal matters more here than anywhere else: the client is a live connection to
/// an injected helper, and one left published after the service stops is what makes every
/// Private API route report a helper that is not there.
protocol PrivateAPIPublishing: Sendable {
  func publishPrivateAPI(client: any PrivateAPI, runtime: PrivateAPIRuntime?) async
  func withdrawPrivateAPI() async
}
