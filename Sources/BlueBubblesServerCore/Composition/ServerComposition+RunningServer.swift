//  ServerComposition+RunningServer
//  The assembled server: starting it and stopping it.
//
//  Beside the composition because it is the composition's product and holds nothing the
//  composition did not build. A start that fails is unwound here rather than by the
//  caller, and a stop flushes what is still pending before the services go.

import BBCore
import BBDiagnostics
import BBHTTPAPI
import BBServiceKit
import Logging

/// An assembled server, not yet started.
public struct RunningServer: Sendable {
  public let context: AppContext
  /// The file the server is logging to. Held so the app's log viewer can tail it without
  /// re-deriving the path, and so a test can point both at the same temporary file.
  public let logSink: FileSink?
  public let registry: ServiceRegistry<AppContext>
  /// Routes settings writes to the services that watch them. Held for its lifetime: it
  /// owns a subscription task, and dropping it would silently stop config propagation.
  public let propagation: SettingsPropagation
  public let handlers: HandlerRegistry
  public let routeGroups: [RouteGroup]
  public let options: ServerComposition.Options
  let logger: Logger

  /// Starts everything, in dependency order.
  public func start() async throws {
    // Mount checked before anything starts, across the WHOLE table rather than just the
    // additive groups: the core table is the part with ~90 routes in it.
    //
    // **This cannot fire in production.** It is not the guard that makes an unhandled route
    // impossible: `PlaceholderHandlers.fill` runs in `buildHandlers` over `RouteTable.alwaysMounted +
    // additionalGroups`, which is a SUPERSET of what this iterates, so `missing` is always
    // empty by the time it is computed and `unregisteredHandlers` can never be thrown.
    //
    // The 501 the placeholders answer with is the deliberate design — an unimplemented route
    // says so rather than 404ing as though it did not exist. What this check protects is a
    // registry assembled BY HAND, which means a test; `HTTPServer` carries the same guard.
    let missing = handlers.missing(for: RouteTable.groups + routeGroups)
    if !missing.isEmpty {
      logger.error(
        "Route handlers are missing",
        metadata: [
          "handlers": .string(missing.map(\.rawValue).joined(separator: ", "))
        ])
      throw HTTPMountError.unregisteredHandlers(missing)
    }

    // Subscribed BEFORE the services start. A service that writes a setting during its
    // own startup (the proxy publishing its address is the live example) must not do
    // it into a stream nobody is reading yet.
    await propagation.start()

    // Anything a previous process left running. Before the proxies start, so the port
    // and the tunnel an orphan holds are free by the time the replacement asks.
    context.daemonLedger.reapOrphans(logger: logger)

    // Before the services, so the first requests and events are counted. The observer is a
    // tap on the bus, not a sink; see `EventBus.dispatchObserver`.
    let metrics = context.metrics
    await context.events.setDispatchObserver { metrics.noteDispatched($0) }
    await metrics.start(sources: context.metricSources())

    do {
      try await AuditContext.acting(as: .system(component: "startup")) {
        try await registry.startAll()
      }
    } catch {
      // A start that fails is unwound HERE, not left to the caller. The app stops the
      // composition when its start throws; the command line does not, and went on to exit
      // with the settings pump and the metrics ticker running and the availability span this
      // start opened never closed. Everything above is undone in the reverse order, services
      // first: `stopAll` stops each service that came up, in reverse start order, and passes
      // over one that never did, so it is right whatever point `startAll` reached.
      logger.error(
        "The server did not start; stopping what had started",
        metadata: ["error": .string(String(describing: error))])
      await AuditContext.acting(as: .system(component: "startup")) {
        await registry.stopAll()
      }
      await metrics.stop()
      await context.events.setDispatchObserver(nil)
      await propagation.stop()
      throw error
    }
    logger.info("Server started")
  }

  /// Stops everything, in exactly the reverse of the start order.
  public func stop() async {
    await propagation.stop()
    // Before the sinks stop: a FindMy position held by the rate limiter is the newest one
    // there is, and it can only reach a socket that is still open.
    await context.events.flushPending()
    // And before the process goes: a block or an unblock made seconds ago may still be
    // queued for its table rewrite, and the whole point of persisting it is that it
    // survives the restart. Same argument as the line above, about durable state rather
    // than deliverable state.
    await context.accessControl.flushPersistedState()
    await AuditContext.acting(as: .system(component: "shutdown")) {
      await registry.stopAll()
    }
    // After the services, so the last minute includes their shutdown, and so the server's
    // availability span ends when the server actually did.
    await context.metrics.stop()
    await context.events.setDispatchObserver(nil)
    logger.info("Server stopped")
  }
}
