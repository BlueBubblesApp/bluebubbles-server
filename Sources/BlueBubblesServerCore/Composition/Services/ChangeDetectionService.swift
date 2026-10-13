//  ChangeDetectionService
//  Watches chat.db and turns writes into events.
//
//  Two signals: a kqueue watcher on chat.db and its WAL is the primary, low-latency one; a
//  `PRAGMA data_version` check every 30 seconds is the backup, and queries only when SQLite
//  says something was committed that the watcher did not report. See `ChangeDetector`.
//
//  Two kinds of event come out of it: the message events, and `chat-read-status-changed`
//  when a chat's last-read time moves forward. That is every `read: true`, the mark-read
//  route's included; the helper observes no read state, so nothing emits it twice. The one
//  `read: false` is `ChatInterface.markUnread`'s, because going unread does not move it.

import BBBuiltIns
import BBCore
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
  typealias Host = any ScopedSettingsProviding & LoggerProviding & EventPublishing
    & MessageSourceProviding & MessageReindexerProviding

  /// Which of these changes altered what a message SAYS.
  ///
  /// Static and named rather than a closure in the pump, for the same reason `event(for:)`
  /// is: it is a rule with cases, and a rule buried in a `for` loop is one nobody can assert
  /// without standing up a detector and a database.
  ///
  /// `.edited` and `.retracted` are the whole list. Every other field the watcher reports —
  /// delivered, read, played, notified, error — is a receipt or a status, and none of them
  /// changes a word. A message that was DELETED is absent here on purpose: its row is gone,
  /// so the index's row id resolves to nothing and the join drops it without being told.
  static func rowIDsNeedingReindex(_ changes: [MessageChange]) -> [Int64] {
    changes
      .filter {
        $0.changedFields.contains(.edited) || $0.changedFields.contains(.retracted)
      }
      .map(\.message.rowID)
  }

  private let scoped: ScopedSettings
  private let events: EventBus
  private let logger: Logger
  private let messages: MessageRepository?
  private let messageSerializer: MessageSerializer?
  /// Held so it can be stopped. The detector is captured by the body alone, so it goes when
  /// the body ends, and takes its poll with it.
  private let pump = OwnedTask()

  init(host: Host) {
    self.scoped = host.scopedSettings(for: Self.manifest)
    self.events = host.events
    self.logger = host.logger
    self.messages = host.messages
    self.messageSerializer = host.serializer
    self.reindexerSource = host
  }

  /// Where the search index's hook is read from, per batch.
  ///
  /// The SOURCE rather than the hook: the indexer publishes and withdraws as the feature is
  /// switched on and off, so a reference captured once would go on writing to a store that
  /// had been closed, or to one the user had just deleted.
  private let reindexerSource: any MessageReindexerProviding

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
    // Captured like the rest, so the pump holds no reference to this service. It is the
    // SOURCE, not the hook, so each batch still reads whatever is published at that moment.
    let reindexerSource = self.reindexerSource

    // Once, here, rather than once per change: without a serializer every change below
    // is dropped, and a line per drop would say the same thing a thousand times.
    if serializer == nil {
      logger.warning("No message serializer; detected changes will not be announced")
    }

    // Started before `start()` returns, so a change written while the rest of the
    // services are still coming up is not missed.
    // Everything the loop reads is captured above as a local, so the pump holds no reference
    // to this service.
    pump.run {
      // Outlives the batches, unlike the hydrator: what it caches is a finished
      // transfer's file, which cannot go stale.
      let files = AttachmentMetadataReader()
      for await batch in await detector.changes(watching: ChatDatabase.defaultPath) {
        let changes = batch.messages
        // One hydrator per batch: long enough to collapse a burst in a single chat into
        // one participants query, short enough that a roster change cannot go stale. See
        // `EventHydrator`.
        var hydrator = EventHydrator(repository: repository, files: files, logger: logger)

        // The search index, before the events. What a message SAYS has changed, and the
        // index built by walking ROWIDs upward never looks back — so this is the only thing
        // that tells it. Done per batch rather than per change so a conversation where
        // several messages were edited at once is one write.
        //
        // `.edited` and `.retracted` only: everything else the watcher reports is a receipt
        // or a status, and none of them changes a word. A DELETED message needs nothing —
        // its row is gone, so the index's row id resolves to nothing and the join drops it.
        let rewritten = Self.rowIDsNeedingReindex(changes)
        if !rewritten.isEmpty, let reindexer = await reindexerSource.messageReindexer() {
          await reindexer.reindex(rowIDs: rewritten)
        }

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

        // After the messages, so a client is told about a message before it is told the
        // chat holding it was read.
        await Self.announce(chatReads: batch.chatReads, to: events, logger: logger)
      }
    } ifItEndsOnItsOwn: { [logger] in
      // A WARNING, so it is in a default log bundle: the symptom is "messages stopped
      // arriving", and without this line there is nothing to find. `isAlive` turns false at
      // the same moment, so the registry revives the service.
      logger.warning(
        "Change detection stopped on its own; no further messages will be detected")
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
    await pump.stop()
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

  /// Emits `chat-read-status-changed` for each chat whose last-read time moved forward.
  ///
  /// Static, and the whole of the step, so a test can hand it a detector's batch and see what
  /// reaches the bus without standing up a watcher on the real `chat.db`.
  static func announce(chatReads: [ChatReadMark], to events: EventBus, logger: Logger) async {
    for mark in chatReads {
      logger.debug(
        "Announcing chat read",
        metadata: [
          "event": .string(EventName.chatReadStatusChanged.rawValue),
          "chat": .string(Redaction.chatGUID(mark.guid)),
        ])
      // Keyed by the chat like typing is. The event has no rate limit today, so the key
      // only matters if it is given one.
      await events.emit(event(forChatRead: mark), rateLimitKey: mark.guid)
    }
  }

  /// `read` is the literal `true` because only an INCREASE is detected; `false` comes from
  /// `ChatInterface.markUnread`, which is the only thing that knows a chat went unread.
  ///
  /// The GUID is the row's own, as chat.db stores it, never rebuilt: a client matches it
  /// against the chats this server has already sent it.
  static func event(forChatRead mark: ChatReadMark) -> ServerEvent {
    .chatReadStatusChanged(chatGUID: mark.guid, read: true)
  }

  /// `.failed` once the pump has ended: the process is up and no message will be noticed,
  /// which `.running` hid until the liveness poll's next tick.
  var health: ServiceHealth {
    get async {
      guard messages != nil else { return .degraded(reason: "no chat.db access") }
      return pump.isRunning ? .running : .failed(reason: "not watching for new messages")
    }
  }

  /// The pump is the service. Without it nothing reads `chat.db` and no event is emitted,
  /// which is the silent failure this reports.
  var isAlive: Bool { get async { pump.isRunning } }
}
