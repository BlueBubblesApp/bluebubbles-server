//  SocketService
//  Registers the socket sink so connected clients hear events, and keeps sessions alive.

import BBBuiltIns
import BBServiceKit
import BBSettings
import BBSocketIO

actor SocketService: ContextualService, ConfigurableService {
  /// Nothing from the manifest — the socket reads no settings — plus the password, for the
  /// same reason `HTTPService` watches it: a revoked password must disconnect whoever
  /// authenticated with it.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.password.key])
  }

  static let manifest = BuiltInManifests.socket

  let context: AppContext

  init(host: AppContext) { self.context = host }

  func start() async throws {
    // Registering the sink is what connects change detection to connected clients: the
    // detector emits onto the bus, the bus fans out to sinks, and this one broadcasts.
    // Without it the events are produced and go nowhere.
    await context.events.register(SocketSink(server: context.socketServer))

    // Heartbeats and session reaping. Without it an idle EIO4 client eventually decides
    // the server is gone, and a client that vanished without closing leaves its session
    // and its queued broadcasts in memory for the life of the process.
    await context.engineIO.startMaintenance()
    context.logger.info("Socket transport ready")
  }

  func stop() async {
    await context.engineIO.stopMaintenance()
    await context.engineIO.closeAll()
    await context.events.unregister(.socket)
  }

  /// A password change must kick connected clients: they authenticated with the old one,
  /// and leaving the socket open means a revoked password keeps working until they happen
  /// to reconnect.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let clients = await context.socketServer.connectionCount
      return clients > 0 ? .running : .degraded(reason: "no clients connected")
    }
  }
}
