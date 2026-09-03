//  ServerEvent
//  The client-facing event vocabulary.
//
//  Every case here exists because a client consumes it, so the names are frozen: they are
//  the socket channel name, the FCM `type` field, and the webhook `type` field all at once.
//  A rename is a client break, not a refactor.
//
//  Note the two that look like typos and are not:
//    - `updated-message`, not `message-updated`. Inconsistent with its siblings; shipped.
//    - `imessage-aliases-removed` (plural) is the event name, while the webhook picker
//      offers `imessage-alias-removed` (singular). Both spellings exist in the codebase and
//      both are reproduced, because a webhook subscribed through the UI holds the singular
//      string and would otherwise match nothing.
//
//  This replaces Server().emitMessage() and the ~30 fan-out call sites that pass its
//  `sendFcmMessage` / `sendSocket` booleans differently, which is a decision that belongs to
//  the event rather than to whoever happens to be emitting it.
//
//  See `docs/EVENTS.md`.

import BBSerialization
import Foundation

public struct EventName: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }
}

extension EventName {
  public static let newMessage = EventName("new-message")
  /// Not "message-updated". The inconsistency is shipped.
  public static let updatedMessage = EventName("updated-message")
  public static let messageSendError = EventName("message-send-error")
  public static let groupNameChange = EventName("group-name-change")
  public static let groupIconChanged = EventName("group-icon-changed")
  public static let groupIconRemoved = EventName("group-icon-removed")
  public static let participantRemoved = EventName("participant-removed")
  public static let participantAdded = EventName("participant-added")
  public static let participantLeft = EventName("participant-left")
  public static let chatReadStatusChanged = EventName("chat-read-status-changed")
  public static let typingIndicator = EventName("typing-indicator")
  public static let helloWorld = EventName("hello-world")
  public static let newServer = EventName("new-server")
  public static let serverUpdate = EventName("server-update")
  public static let serverUpdateDownloading = EventName("server-update-downloading")
  public static let serverUpdateInstalling = EventName("server-update-installing")
  public static let incomingFaceTime = EventName("incoming-facetime")
  public static let faceTimeCallStatusChanged = EventName("ft-call-status-changed")
  public static let newFindMyLocation = EventName("new-findmy-location")
  public static let iMessageAliasesRemoved = EventName("imessage-aliases-removed")

  public static let scheduledMessageError = EventName("scheduled-message-error")
  public static let scheduledMessageSent = EventName("scheduled-message-sent")
  public static let scheduledMessageDeleted = EventName("scheduled-message-deleted")
  public static let scheduledMessageUpdated = EventName("scheduled-message-updated")
  public static let scheduledMessageCreated = EventName("scheduled-message-created")

  public static let settingsBackupCreated = EventName("settings-backup-created")
  public static let settingsBackupDeleted = EventName("settings-backup-deleted")
  public static let settingsBackupUpdated = EventName("settings-backup-updated")
  public static let themeBackupCreated = EventName("theme-backup-created")
  public static let themeBackupDeleted = EventName("theme-backup-deleted")
  public static let themeBackupUpdated = EventName("theme-backup-updated")

  /// What the webhook settings UI offers, which is not identical to the set above:
  /// `imessage-alias-removed` here is singular, while the event emitted is plural. A
  /// webhook subscribed through the UI carries the singular string, so matching has to
  /// accept both.
  public static let webhookSubscribable: [EventName] = [
    .newMessage, .updatedMessage, .messageSendError, .groupNameChange,
    .groupIconChanged, .groupIconRemoved, .participantRemoved, .participantAdded,
    .participantLeft, .chatReadStatusChanged, .typingIndicator,
    .scheduledMessageError, .serverUpdate, .newServer, .newFindMyLocation,
    .helloWorld, .incomingFaceTime, .faceTimeCallStatusChanged,
    EventName("imessage-alias-removed"),
    .themeBackupCreated, .themeBackupUpdated, .themeBackupDeleted,
    .settingsBackupCreated, .settingsBackupUpdated, .settingsBackupDeleted,
  ]

  /// The singular spelling the UI offers for the plural event we emit.
  public var webhookAliases: Set<String> {
    if self == .iMessageAliasesRemoved { return [rawValue, "imessage-alias-removed"] }
    return [rawValue]
  }
}

// MARK: - The event

/// An event plus its already-projected payloads.
///
/// The two projections are computed once at construction, not per sink. The current code
/// calls `serialize()` twice at each of ~15 fan-out sites — once with
/// `isForNotification: false` for the socket and once with `true` for FCM and webhooks —
/// which is both duplicated work and duplicated opportunity to get the flag backwards.
public struct ServerEvent: Sendable {
  public let name: EventName
  /// What the socket receives: the full object.
  public let fullPayload: JSONValue
  /// What FCM and webhooks receive: ~18 fields lighter, size-capped for the 4KB FCM limit.
  /// Identical to `fullPayload` for events that carry no message.
  public let notificationPayload: JSONValue
  public let priority: EventPriority
  public let occurredAt: Date

  public init(
    name: EventName,
    fullPayload: JSONValue,
    notificationPayload: JSONValue? = nil,
    priority: EventPriority = .normal,
    occurredAt: Date = Date()
  ) {
    self.name = name
    self.fullPayload = fullPayload
    self.notificationPayload = notificationPayload ?? fullPayload
    self.priority = priority
    self.occurredAt = occurredAt
  }

  /// The payload a given sink should send.
  public func payload(for projection: PayloadProjection) -> JSONValue {
    switch projection {
    case .full: fullPayload
    case .notification: notificationPayload
    }
  }
}

public enum EventPriority: String, Sendable {
  case normal
  case high
}

public enum PayloadProjection: Sendable {
  case full
  case notification
}

// MARK: - Routing policy

/// Which sinks an event reaches, declared on the event rather than decided at the call site.
///
/// In the current server these decisions live as extra boolean arguments to `emitMessage`
/// (`sendFcmMessage`, `sendSocket`) passed differently at each of ~15 sites. Centralizing
/// them means a new sink automatically gets the right treatment for every event instead of
/// needing another argument threaded through every caller.
public struct EventRouting: Sendable {
  public let allowsSocket: Bool
  public let allowsPush: Bool
  public let allowsWebhooks: Bool
  /// Minimum gap between deliveries of this event. Applied per chat where the event has
  /// one, so a busy chat cannot starve a quiet one.
  public let minimumInterval: Duration?
  /// Ignores the per-event key and rate-limits the event type as a whole.
  ///
  /// For most events a shared bucket is wrong: one busy chat would starve every quiet one.
  /// FindMy is the exception, because its limit protects an UPSTREAM service rather than
  /// this server's own delivery — per-device buckets would multiply the request rate by the
  /// device count, which is the opposite of what the limit is for.
  public let isRateLimitGlobal: Bool

  public init(
    allowsSocket: Bool = true,
    allowsPush: Bool = true,
    allowsWebhooks: Bool = true,
    minimumInterval: Duration? = nil,
    isRateLimitGlobal: Bool = false
  ) {
    self.allowsSocket = allowsSocket
    self.allowsPush = allowsPush
    self.allowsWebhooks = allowsWebhooks
    self.minimumInterval = minimumInterval
    self.isRateLimitGlobal = isRateLimitGlobal
  }

  public static let `default` = EventRouting()

  /// Per-event routing.
  ///
  /// **The reference's two push suppressions are NOT here any more.** They were, transcribed
  /// from `emitMessage(type, data, priority, sendFcmMessage: false)` at two call sites — and
  /// they were applied by the BUS, above every notification transport, which made them a
  /// rule about notifications in general. They are not: they are a rule about FIREBASE, and
  /// the reference delivers both events to webhooks quite happily. Applying them at the bus
  /// meant ntfy lost `typing-indicator` and `new-findmy-location` the moment it moved to
  /// push routing, when under v1 — where ntfy is a webhook — it received them.
  ///
  /// They now live in `FirebaseProvider.referenceSubscription`, where the transcription
  /// comment sits next to the transport it describes. `allowsPush` stays as the class gate
  /// and is currently open for every event; a suppression that genuinely applies to every
  /// notification transport would belong here.
  ///
  /// Webhooks have no suppression flag at all: `webhookService.dispatch` runs
  /// unconditionally, so every event reaches subscribed webhooks.
  public static func policy(for name: EventName) -> EventRouting {
    switch name {
    case .newFindMyLocation:
      // `emitMessage(NEW_FINDMY_LOCATION, …, "normal", false, true)` — push off,
      // socket on. Location updates arrive in bursts and would burn FCM quota.
      //
      // The 250ms gap is the current handler's `waitMs(250)` between items in a batch,
      // expressed here as policy instead of a sleep in the emit loop — the sleep
      // blocks the whole handler, so a 40-device batch stalls FindMy processing for
      // ten seconds.
      //
      // Deliberately rate-limited GLOBALLY rather than per device, which is the one
      // place this differs from the chat-keyed limits elsewhere. The server is a
      // FindMy client as far as Apple is concerned, and Apple does not like being
      // polled hard; keying per device would multiply the permitted rate by the number
      // of devices, which is exactly the pressure the limit exists to avoid. The
      // limiter coalesces rather than drops, so the newest batch still gets through —
      // it is the RATE that is capped, not the freshness.
      // The RATE limit stays here: it protects Apple from this server's polling, which is
      // true whatever the event is delivered over. Only the push suppression moved.
      EventRouting(
        allowsSocket: true, allowsPush: true, allowsWebhooks: true,
        minimumInterval: .milliseconds(250),
        isRateLimitGlobal: true
      )

    default:
      .default
    }
  }
}
