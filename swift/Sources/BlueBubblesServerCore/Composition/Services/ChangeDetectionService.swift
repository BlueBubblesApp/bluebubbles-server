//  ChangeDetectionService
//  Watches chat.db and turns writes into events.

import BBEvents
import BBIMessage
import BBSerialization
import BBServiceKit
import BBSettings

/// Watches chat.db and turns writes into events.
final class ChangeDetectionService: ContextualService, PermissionDependentService,
  ConfigurableService
{
  static let manifest = BuiltInManifests.changeDetection
  /// The poll interval is read once, at start, to build the detector — so without this the
  /// setting was inert: a user lowering it to get faster message delivery saw no change
  /// until the next launch, and nothing said why.
  static let watchedSettings: Set<String> = [Settings.dbPollInterval.key]
  /// The one permission that genuinely gates a service: without Full Disk Access there is
  /// no database to watch, and the registry reports that precisely instead of letting this
  /// fail obscurely at first read.
  static let requiredPermissions: [PermissionID] = [.fullDiskAccess]
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  let context: AppContext
  /// Held so it can be cancelled. The detector's stream ends when the task does.
  private let pump = TaskBox()

  init(host: AppContext) { self.context = host }

  func start() async throws {
    guard let repository = context.messages else {
      throw ServiceStartupError.unavailable("chat.db is not readable")
    }

    var configuration = ChangeDetectorConfiguration()
    configuration.pollInterval = .milliseconds(
      await context.settings.get(Settings.dbPollInterval)
    )

    let detector = ChangeDetector(repository: repository, configuration: configuration)
    let events = context.events
    let serializer = context.serializer
    let logger = context.logger

    // Started before `start()` returns, so a change written while the rest of the
    // services are still coming up is not missed.
    await pump.set(
      Task {
        for await changes in await detector.changes(watching: ChatDatabase.defaultPath) {
          for change in changes {
            guard let event = Self.event(for: change, serializer: serializer) else {
              continue
            }
            // Rate-limited per chat where the policy asks for it, so a busy
            // conversation cannot starve a quiet one. `cacheRoomnames` is the chat
            // the row belongs to as chat.db records it; a message with none is
            // rate-limited globally, which is correct — it has no chat to key on.
            await events.emit(
              event, rateLimitKey: change.message.cacheRoomnames
            )
          }
        }
        logger.debug("Change detection stopped")
      })

    let pollInterval = await context.settings.get(Settings.dbPollInterval)
    context.logger.info(
      "Watching chat.db for changes",
      metadata: [
        "pollMs": .stringConvertible(pollInterval)
      ])
  }

  /// Rebuilt rather than reconfigured: the interval is baked into the detector when it is
  /// constructed and cannot be changed on a running one.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  func stop() async {
    await pump.cancel()
  }

  /// Maps a detected change onto the client-facing event vocabulary.
  ///
  /// Returns nil for changes with no client event — not every column that moves is
  /// something a client is told about, and emitting one anyway would be a new event name
  /// no client knows.
  static func event(
    for change: MessageChange,
    serializer: MessageSerializer?
  ) -> ServerEvent? {
    guard let serializer else { return nil }
    let payload = serializer.serialize(
      change.message, context: MessageSerializer.Context(), config: .full
    )
    let notification = serializer.serialize(
      change.message, context: MessageSerializer.Context(),
      config: .notification, isForNotification: true
    )

    // `isNew` distinguishes an insert from an update; the changed-field set says what
    // moved. An error is reported as its own event because clients surface it
    // differently from an ordinary update.
    let name: EventName
    if change.changedFields.contains(.error), change.message.error != 0 {
      name = .messageSendError
    } else {
      name = change.isNew ? .newMessage : .updatedMessage
    }

    return ServerEvent(
      name: name, fullPayload: payload, notificationPayload: notification
    )
  }

  var health: ServiceHealth {
    get async { await context.hasMessageAccess ? .running : .degraded(reason: "no chat.db access") }
  }
}
