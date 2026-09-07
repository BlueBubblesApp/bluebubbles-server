//  SocketService
//  Registers the socket sink so connected clients hear events, and keeps sessions alive.

import BBBuiltIns
import BBEvents
import BBInterfaces
import BBServiceKit
import BBSettings
import BBSocketIO
import Logging

actor SocketService: Service, ConfigurableService {
  /// Nothing from the manifest — the socket reads no settings — plus the password, for the
  /// same reason `HTTPService` watches it: a revoked password must disconnect whoever
  /// authenticated with it.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.password.key])
  }

  static let manifest = BuiltInManifests.socket

  /// What this service touches, rather than the container that holds it.
  typealias Host = any LoggerProviding & EventPublishing & SocketRuntimeProviding

  private let events: EventBus
  private let socketServer: SocketServer
  private let engineIO: EngineIOServer
  private let logger: Logger

  init(host: Host) {
    self.events = host.events
    self.socketServer = host.socketServer
    self.engineIO = host.engineIO
    self.logger = host.logger
  }

  func start() async throws {
    // Registering the sink is what connects change detection to connected clients: the
    // detector emits onto the bus, the bus fans out to sinks, and this one broadcasts.
    // Without it the events are produced and go nowhere.
    await events.register(SocketSink(server: socketServer))

    // Heartbeats and session reaping. Without it an idle EIO4 client eventually decides
    // the server is gone, and a client that vanished without closing leaves its session
    // and its queued broadcasts in memory for the life of the process.
    await engineIO.startMaintenance()
    logger.info("Socket transport ready")
  }

  func stop() async {
    await engineIO.stopMaintenance()
    await engineIO.closeAll()
    await events.unregister(.socket)
  }

  /// A password change must kick connected clients: they authenticated with the old one,
  /// and leaving the socket open means a revoked password keeps working until they happen
  /// to reconnect.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let clients = await socketServer.connectionCount
      return clients > 0 ? .running : .degraded(reason: "no clients connected")
    }
  }
}
