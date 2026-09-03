//  ChangeDetectionService
//  Watches chat.db and turns writes into events.

import BBBuiltIns
import BBEvents
import BBIMessage
import BBSerialization
import BBServiceKit
import BBSettings

/// Watches chat.db and turns writes into events.
actor ChangeDetectionService: ContextualService, PermissionDependentService,
  ConfigurableService
{
  static let manifest = BuiltInManifests.changeDetection
  /// The one permission that genuinely gates a service: without Full Disk Access there is
  /// no database to watch, and the registry reports that precisely instead of letting this
  /// fail obscurely at first read.
  static let requiredPermissions: [PermissionID] = [.fullDiskAccess]
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  let context: AppContext
  /// Held so it can be cancelled. The detector's stream ends when the task does.
  private var pump: Task<Void, Never>?

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
    pump?.cancel()
    pump = Task {
      for await changes in await detector.changes(watching: ChatDatabase.defaultPath) {
        // One hydrator per batch: long enough to collapse a burst in a single chat into
        // one participants query, short enough that a roster change cannot go stale. See
        // `EventHydrator`.
        var hydrator = EventHydrator(repository: repository)
        for change in changes {
          guard
            let event = await Self.event(
              for: change, serializer: serializer, hydrator: &hydrator
            )
          else {
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
    }

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
    pump?.cancel()
    pump = nil
  }

  /// Maps a detected change onto the client-facing event vocabulary.
  ///
  /// Returns nil for changes with no client event — not every column that moves is
  /// something a client is told about, and emitting one anyway would be a new event name
  /// no client knows.
  static func event(
    for change: MessageChange,
    serializer: MessageSerializer?,
    hydrator: inout EventHydrator
  ) async -> ServerEvent? {
    guard let serializer else { return nil }

    // ONE context for both payloads. The two projections differ in whether they EMIT
    // participants — `.full` sets `loadChatParticipants: false` and ignores whatever the
    // context holds — so loading them once and letting the socket projection drop them is
    // the same output for half the queries.
    let relations = await hydrator.context(for: change.message, withParticipants: true)

    let payload = serializer.serialize(
      change.message, context: relations, config: .full
    )
    let notification = serializer.serialize(
      change.message, context: relations,
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
    get async { context.hasMessageAccess ? .running : .degraded(reason: "no chat.db access") }
  }
}
