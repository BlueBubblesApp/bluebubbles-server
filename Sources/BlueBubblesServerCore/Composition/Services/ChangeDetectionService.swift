//  ChangeDetectionService
//  Watches chat.db and turns writes into events.
//
//  Two signals: a kqueue watcher on chat.db and its WAL is the primary, low-latency one; a
//  `PRAGMA data_version` check every 30 seconds is the backup, and queries only when SQLite
//  says something was committed that the watcher did not report. See `ChangeDetector`.

import BBBuiltIns
import BBEvents
import BBIMessage
import BBInterfaces
import BBSerialization
import BBServiceKit
import BBSettings
import Logging

/// Watches chat.db and turns writes into events.
actor ChangeDetectionService: Service, ConfigurableService {
  static let manifest = BuiltInManifests.changeDetection
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  /// What this service touches, rather than the container that holds it.
  typealias Host = any SettingsProviding & LoggerProviding & EventPublishing
    & MessageSourceProviding

  private let scoped: ScopedSettings
  private let events: EventBus
  private let logger: Logger
  private let messages: MessageRepository?
  private let messageSerializer: MessageSerializer?
  /// Held so it can be cancelled. The detector's stream ends when the task does.
  private var pump: Task<Void, Never>?

  init(host: Host) {
    self.scoped = ScopedSettings(
      store: host.settings, manifest: Self.manifest, secretKeys: Settings.secretKeys,
      logger: host.logger
    )
    self.events = host.events
    self.logger = host.logger
    self.messages = host.messages
    self.messageSerializer = host.serializer
  }

  func start() async throws {
    guard let repository = messages else {
      throw ServiceStartupError.unavailable("chat.db is not readable")
    }

    var configuration = ChangeDetectorConfiguration()
    // Clamped here as well as validated on write: an install that stored a sub-30s value
    // under the old meaning of the key must not come up polling.
    configuration.backupInterval = .milliseconds(
      max(30_000, try await scoped.get(Settings.dbPollInterval))
    )

    let detector = ChangeDetector(repository: repository, configuration: configuration)
    let events = self.events
    let serializer = self.messageSerializer
    let logger = self.logger

    // Once, here, rather than once per change: without a serializer every change below
    // is dropped, and a line per drop would say the same thing a thousand times.
    if serializer == nil {
      logger.warning("No message serializer; detected changes will not be announced")
    }

    // Started before `start()` returns, so a change written while the rest of the
    // services are still coming up is not missed.
    // `[weak self]` so the pump does not hold the service alive: everything the loop reads is
    // captured above as a local, and `self` is touched only to report the pump ending.
    pump?.cancel()
    pump = Task { [weak self] in
      for await changes in await detector.changes(watching: ChatDatabase.defaultPath) {
        // One hydrator per batch: long enough to collapse a burst in a single chat into
        // one participants query, short enough that a roster change cannot go stale. See
        // `EventHydrator`.
        var hydrator = EventHydrator(repository: repository, logger: logger)
        for change in changes {
          guard
            let event = await Self.event(
              for: change, serializer: serializer, hydrator: &hydrator
            )
          else {
            continue
          }
          // The one line per message a reader at debug follows. The GUID is opaque and
          // the room name is a `chat…` identifier, so neither needs redacting; the text
          // and subject are content and are never here.
          logger.debug(
            "Announcing message change",
            metadata: [
              "event": .string(event.name.rawValue),
              "guid": .string(change.message.guid),
              "new": .stringConvertible(change.isNew),
              "fields": .string(
                change.changedFields.map(\.rawValue).sorted().joined(separator: ",")),
              "fromMe": .stringConvertible(change.message.isFromMe),
              "attachments": .stringConvertible(change.message.cacheHasAttachments),
              "room": .string(change.message.cacheRoomnames ?? "-"),
            ])
          // Rate-limited per chat where the policy asks for it, so a busy
          // conversation cannot starve a quiet one. `cacheRoomnames` is the chat
          // the row belongs to as chat.db records it; a message with none is
          // rate-limited globally, which is correct; it has no chat to key on.
          await events.emit(
            event, rateLimitKey: change.message.cacheRoomnames
          )
        }
      }
      // WARNING, not debug, and the handle is cleared.
      //
      // This line was `debug`, below the default level, and the pump handle was left set — so
      // a pump that ended left `health` reporting `.running` for a service whose whole job had
      // stopped, with nothing in a default log bundle. The symptom is "messages stopped
      // arriving" and there was nothing to find.
      //
      // Clearing the handle is what makes `isAlive` answerable: a `Task` cannot be asked
      // whether its body has returned, so the body says so on the way out. Same shape as
      // `HTTPListener.handleExit`.
      await self?.pumpEnded()
    }

    logger.info(
      "Watching chat.db for changes",
      metadata: [
        "debounceMs": .stringConvertible(Int(configuration.pollInterval.seconds * 1000)),
        "backupS": .stringConvertible(configuration.backupInterval.seconds),
      ])
  }

  /// Rebuilt rather than reconfigured: the backup interval is baked into the detector when
  /// it is constructed and cannot be changed on a running one.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  func stop() async {
    pump?.cancel()
    pump = nil
  }

  /// Maps a detected change onto the client-facing event vocabulary.
  ///
  /// Returns nil for changes with no client event: not every column that moves is
  /// something a client is told about, and emitting one anyway would be a new event name
  /// no client knows.
  static func event(
    for change: MessageChange,
    serializer: MessageSerializer?,
    hydrator: inout EventHydrator
  ) async -> ServerEvent? {
    guard let serializer else { return nil }

    // NAMED FIRST, because the name decides the notification shape and therefore whether
    // the participants are worth loading at all.
    //
    // `isNew` distinguishes an insert from an update; the changed-field set says what
    // moved. An error is reported as its own event because clients surface it
    // differently from an ordinary update.
    let name: EventName
    if change.changedFields.contains(.error), change.message.error != 0 {
      name = .messageSendError
    } else {
      name = change.isNew ? .newMessage : .updatedMessage
    }

    // The reference uses THREE shapes here, not two, and the differences are its own:
    //
    //   new-message      socket `.full`  ·  FCM `DEFAULT` (participants on, chats on)
    //   updated-message  socket `.full`  ·  FCM participants OFF, chats OFF
    //   send-error       one payload for both: participants OFF, chats on
    //
    // We sent `.notification` to all three, so every edit, unsend, reaction and read
    // receipt pushed a chat object and its whole roster — the thing `FCMSender` then has to
    // shed against Google's 4 KB cap.
    let notificationConfig: MessageSerializerConfig =
      switch name {
      case .updatedMessage: .notificationUpdate
      case .messageSendError: .notificationSendError
      default: .notification
      }

    // ONE context for both payloads. `.full` sets `loadChatParticipants: false` and ignores
    // whatever the context holds, so the participants are loaded for the NOTIFICATION alone
    // — and only `.notification` wants them. On an update, which is the majority of traffic
    // on a busy chat, that query is now not run.
    let relations = await hydrator.context(
      for: change.message, withParticipants: notificationConfig.loadChatParticipants)

    let payload = serializer.serialize(
      change.message, context: relations, config: .full
    )
    let notification = serializer.serialize(
      change.message, context: relations,
      config: notificationConfig, isForNotification: true
    )

    // FCM priority, and it is not cosmetic: a `normal`-priority data message is DEFERRED by
    // Android under Doze and App Standby, so an incoming iMessage can arrive minutes late on a
    // phone that has been idle. Every event here defaulted to `.normal`, which made that the
    // behaviour for every notification this server sends.
    //
    // The reference: `index.ts:1556` emits NEW_MESSAGE at `newMessage.isFromMe ? "normal" :
    // "high"`, and every other emit in that file — MESSAGE_UPDATED at `:1602`, and the six
    // group events at `:1365`-`:1510` — passes the literal `"normal"`. So high is exactly one
    // case: a new message somebody else sent. A message the user sent themselves has already
    // been seen on the device that sent it, which is why the reference splits on `isFromMe`
    // rather than sending every new message at high priority.
    //
    // `.messageSendError` stays normal with the rest: the reference has no high-priority emit
    // for it, and it is a report about the user's own outgoing message.
    let priority: EventPriority =
      name == .newMessage && !change.message.isFromMe ? .high : .normal

    return ServerEvent(
      name: name, fullPayload: payload, notificationPayload: notification,
      priority: priority
    )
  }

  /// Records that the pump has stopped, whether it was asked to or not.
  ///
  /// `stop()` clears the handle first, so a deliberate shutdown reaches this with nothing to
  /// report and says nothing.
  private func pumpEnded() {
    guard pump != nil else { return }
    pump = nil
    logger.warning(
      "Change detection stopped on its own; no further messages will be detected")
  }

  var health: ServiceHealth {
    get async { messages != nil ? .running : .degraded(reason: "no chat.db access") }
  }

  /// The pump is the service. Without it nothing reads `chat.db` and no event is emitted,
  /// which is the silent failure this reports.
  var isAlive: Bool { get async { pump != nil } }
}
