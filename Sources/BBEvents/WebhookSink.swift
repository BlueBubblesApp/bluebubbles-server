//  WebhookSink / NtfySink
//  Outbound HTTP delivery, written against CustomEventSink.
//
//  Both are deliberately implemented through the public extension surface rather than being
//  special-cased inside the bus. That is the standing proof the seam is expressive enough:
//  if a built-in needs a private hook, the extension API is not good enough yet.
//
//  The body shape is fixed by the contract: `{"type": "<event-name>", "data": <payload>}`,
//  posted as JSON. Consumers parse it, so it does not change.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBDiagnostics
import BBSerialization
import Foundation
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Webhook

public struct WebhookTarget: Sendable, Identifiable {
  public let id: Int64
  public let url: String
  /// Event names, or `["*"]` for everything.
  public let events: [String]
  /// Per-target, and separate from the server preference on purpose: a self-hosted
  /// consumer on the same LAN has entirely different trust properties from Google's push
  /// infrastructure, so it can stay on legacy-v1 while FCM moves to sealed-v2.
  public let codecs: Set<CodecIdentifier>
  /// Whether delivery may follow a 3xx.
  ///
  /// Per-target and off for a new webhook, because the URL is the whole of what an operator
  /// approved: `URLSession` follows redirects by default, so a 3xx from an approved endpoint
  /// could re-point the POST — message content included — at anything this server can reach,
  /// loopback included. Some endpoints legitimately redirect (a load balancer, a moved path),
  /// so it is a switch rather than a prohibition. See `InterfacesSchema`'s migration for why
  /// webhooks that predate the column are `true`.
  public let followRedirects: Bool
  /// Which conversations' events this endpoint receives. Narrows the chat events that
  /// `events` already admits and leaves every other event alone; see `ChatScope`.
  public let chatScope: ChatScope
  /// What happens after a failed delivery. Off unless the webhook says otherwise; see
  /// `WebhookRetryPolicy`.
  public let retryPolicy: WebhookRetryPolicy

  public init(
    id: Int64, url: String, events: [String], codecs: Set<CodecIdentifier> = [.legacyV1],
    followRedirects: Bool = false, chatScope: ChatScope = .allChats,
    retryPolicy: WebhookRetryPolicy = .off
  ) {
    self.id = id
    self.url = url
    self.events = events
    self.codecs = codecs
    self.followRedirects = followRedirects
    self.chatScope = chatScope
    self.retryPolicy = retryPolicy
  }

  /// Whether this endpoint is sent an event: subscribed to its name, and, for an event about
  /// a conversation, to that conversation. `chatGUIDs` is `event.chatGUIDs`, passed in so a
  /// sink checking one event against every target reads the payload once.
  func receives(_ event: ServerEvent, chatGUIDs: [String]?) -> Bool {
    matches(event.name) && chatScope.admits(chatGUIDs: chatGUIDs)
  }

  func matches(_ name: EventName) -> Bool {
    if events.contains("*") { return true }
    // Checked against the alias set, since the settings UI offers
    // `imessage-alias-removed` (singular) for an event emitted as
    // `imessage-aliases-removed` (plural). Matching only the exact name would make that
    // subscription silently dead.
    return !name.webhookAliases.isDisjoint(with: Set(events))
  }
}

public actor WebhookSink: CustomEventSink {

  public nonisolated let id = SinkID.webhook
  public let routing = SinkRouting.webhook
  public nonisolated let projection = PayloadProjection.notification

  private let targets: @Sendable () async -> [WebhookTarget]
  private let negotiator: CodecNegotiator
  private let transport: any HTTPPosting
  private let logger: Logger
  private let alerts: (any AlertRaising)?

  /// Consecutive failures per target, and the last outcome for each: held in the tracker
  /// rather than in a private field here, so the settings list can show what this actor
  /// knows. A single failed POST is noise; a target that has been failing for a while is
  /// worth telling the user about, once.
  private let deliveries: WebhookDeliveryTracker
  private var alerted: Set<Int64> = []
  private let failuresBeforeAlert = 10

  /// The events waiting for each failing endpoint. See `WebhookRetry.swift`.
  private var outboxes = WebhookOutboxes()
  /// Sleeps until the earliest outbox is due. One task for every outbox, re-armed whenever
  /// that moment moves, rather than a timer per event.
  private var wake: Task<Void, Never>?
  private var wakeAt: ContinuousClock.Instant?
  /// Off in tests, which send from the outboxes by calling `runDueRetries(at:)` with a time
  /// of their choosing instead of waiting for the clock.
  private var isRetryTimerEnabled = true
  /// Set by `stopRetrying`. Nothing opens an outbox or sends from one after it.
  private var isStopped = false

  public init(
    targets: @escaping @Sendable () async -> [WebhookTarget],
    negotiator: CodecNegotiator = .legacyOnly(),
    transport: any HTTPPosting = URLSessionPoster(),
    logger: Logger = Logger(label: "bluebubbles.webhooks"),
    alerts: (any AlertRaising)? = nil,
    deliveries: WebhookDeliveryTracker = WebhookDeliveryTracker()
  ) {
    self.targets = targets
    self.negotiator = negotiator
    self.transport = transport
    self.logger = logger
    self.alerts = alerts
    self.deliveries = deliveries
  }

  deinit {
    wake?.cancel()
  }

  public func accepts(_ event: ServerEvent) async -> Bool {
    let chats = event.chatGUIDs
    return await targets().contains { $0.receives(event, chatGUIDs: chats) }
  }

  public func deliver(_ event: ServerEvent) async throws {
    let chats = event.chatGUIDs
    let matching = await targets().filter { $0.receives(event, chatGUIDs: chats) }
    guard !matching.isEmpty else { return }

    // An endpoint with an outbox open is not sent this event now: it goes to the back of
    // the outbox, so the endpoint receives events in order and is not tried again before
    // its backoff says so. Decided before anything awaits, so no event can slip in ahead.
    var direct: [WebhookTarget] = []
    var queued: [WebhookTarget] = []
    for target in matching {
      if outboxes.isBackingOff(target.id, url: target.url) {
        if queue(event, behind: target) { queued.append(target) }
      } else {
        direct.append(target)
      }
    }
    for target in queued {
      await deliveries.noteBacklog(
        id: target.id, url: target.url, waiting: outboxes.waiting(target.id),
        nextAttemptAt: nextAttemptDate(target.id))
    }

    // Bounded concurrency rather than one task per target: a user with fifty webhooks
    // should not open fifty sockets at once on a machine this is meant to run on.
    await withTaskGroup(of: Void.self) { group in
      var running = 0
      for target in direct {
        if running >= 8 {
          await group.next()
          running -= 1
        }
        group.addTask { await self.deliverFirst(event, to: target) }
        running += 1
      }
    }
  }

  // MARK: - Attempts

  /// The first attempt at an event, made from the lane. A retryable failure opens the
  /// endpoint's outbox with this event at its head.
  private func deliverFirst(_ event: ServerEvent, to target: WebhookTarget) async {
    let deliveryID = UUID()
    let started = ContinuousClock.now
    let error = await send(event, to: target, deliveryID: deliveryID, attempt: 1)

    if let error, !isStopped, target.retryPolicy.isEnabled,
      WebhookRetryPolicy.retries(event.name), WebhookRetryPolicy.isRetryable(error)
    {
      let now = ContinuousClock.now
      outboxes.open(
        with: WebhookOutboxes.Entry(event: event, deliveryID: deliveryID, attemptsMade: 1),
        id: target.id, url: target.url,
        delay: target.retryPolicy.delay(afterFailures: 1, jitter: .random(in: 0..<1)),
        now: now
      )
      armWake()
    }
    await report(event, to: target, attempt: 1, error: error, started: started)
  }

  /// Puts an event at the back of an endpoint's outbox. Returns whether it was queued.
  private func queue(_ event: ServerEvent, behind target: WebhookTarget) -> Bool {
    // A typing indicator would be stale by the time the outbox reached it.
    guard WebhookRetryPolicy.retries(event.name) else { return false }
    let firstDrop = outboxes.append(
      WebhookOutboxes.Entry(event: event, deliveryID: UUID(), attemptsMade: 0), id: target.id)
    if firstDrop {
      logger.warning(
        "A webhook's retry outbox is full; its oldest waiting events are being dropped",
        metadata: [
          "url": .string(Redaction.url(target.url)),
          "capacity": .stringConvertible(WebhookOutboxes.capacity),
        ])
    }
    return true
  }

  /// Sends from one endpoint's outbox, oldest first, until it is empty or the endpoint
  /// fails again. The caller has marked the outbox as draining (`takeDue`).
  private func drain(_ id: Int64) async {
    while !isStopped {
      // Read per event, so an edit made while a backlog drains applies to the rest of it.
      let current = await targets().first { $0.id == id }
      guard let target = current, outboxes.isBackingOff(id, url: target.url) else {
        // Removed, or moved to another URL: the backlog was for an endpoint that is no
        // longer there.
        let dropped = outboxes.discard(id)
        if dropped > 0 {
          logger.info(
            "Discarded a webhook's retry outbox; the webhook was removed or changed",
            metadata: ["id": .stringConvertible(id), "events": .stringConvertible(dropped)])
        }
        break
      }
      guard var entry = outboxes.takeHead(id) else { break }
      // Unsubscribed from this event, or from its conversation, since it was queued.
      guard target.receives(entry.event, chatGUIDs: entry.event.chatGUIDs) else { continue }

      entry.attemptsMade += 1
      let started = ContinuousClock.now
      let error = await send(
        entry.event, to: target, deliveryID: entry.deliveryID, attempt: entry.attemptsMade)

      guard let error else {
        outboxes.delivered(id, now: .now)
        await report(
          entry.event, to: target, attempt: entry.attemptsMade, error: nil, started: started)
        continue
      }

      let retryable = WebhookRetryPolicy.isRetryable(error)
      let result = outboxes.failed(
        entry, id: id, retryable: retryable, policy: target.retryPolicy,
        delay: target.retryPolicy.delay(
          afterFailures: outboxes.failures(id) + 1, jitter: .random(in: 0..<1)),
        now: .now
      )
      await report(
        entry.event, to: target, attempt: entry.attemptsMade, error: error, started: started)
      if result == .gaveUp {
        // Info, not debug: this is an event the endpoint will never receive.
        logger.info(
          "Gave up delivering an event to a webhook",
          metadata: [
            "url": .string(Redaction.url(target.url)),
            "event": .string(entry.event.name.rawValue),
            "attempts": .stringConvertible(entry.attemptsMade),
            "reason": .string(WebhookDeliveryState.reason(for: error)),
          ])
      }
      // A retryable failure means the endpoint is still down: wait out the backoff. One
      // that is not was about this request, and the next event may well get through.
      if retryable { break }
    }
    outboxes.finishDraining(id)
    armWake()
  }

  /// One POST. The error, or nil when the endpoint accepted it.
  private func send(
    _ event: ServerEvent, to target: WebhookTarget, deliveryID: UUID, attempt: Int
  ) async -> (any Error)? {
    do {
      // The same call the test send makes. A separate implementation here would mean
      // "Send Test" could pass while real delivery was broken.
      try await WebhookDelivery.send(
        event, to: target, negotiator: negotiator, transport: transport,
        projection: projection, deliveryID: deliveryID, attempt: attempt
      )
      return nil
    } catch {
      return error
    }
  }

  /// Records an attempt where the settings page reads it, logs it, and raises the alert
  /// once a failure has become persistent. Called AFTER the outbox has been updated, so the
  /// row shows what is waiting as of this attempt.
  private func report(
    _ event: ServerEvent, to target: WebhookTarget, attempt: Int, error: (any Error)?,
    started: ContinuousClock.Instant
  ) async {
    let waiting = outboxes.waiting(target.id)
    let next = nextAttemptDate(target.id)

    guard let error else {
      await deliveries.record(
        id: target.id, url: target.url, event: event.name.rawValue, outcome: .delivered,
        waiting: waiting, nextAttemptAt: next
      )
      alerted.remove(target.id)
      // The URL is redacted before it reaches a log, here and below: clients routinely
      // register webhook URLs with the server password in the query string.
      logger.debug(
        "Webhook delivered",
        metadata: [
          "url": .string(Redaction.url(target.url)),
          "event": .string(event.name.rawValue),
          "attempt": .stringConvertible(attempt),
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
        ])
      return
    }

    let reason = WebhookDeliveryState.reason(for: error)
    let count = await deliveries.record(
      id: target.id, url: target.url, event: event.name.rawValue, outcome: .failed(reason),
      waiting: waiting, nextAttemptAt: next
    )

    logger.debug(
      "Webhook dispatch failed",
      metadata: [
        "url": .string(Redaction.url(target.url)),
        "event": .string(event.name.rawValue),
        "attempt": .stringConvertible(attempt),
        "failures": .stringConvertible(count),
        "waiting": .stringConvertible(waiting),
        "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
        "reason": .string(reason),
      ])

    if count >= failuresBeforeAlert && !alerted.contains(target.id) {
      alerted.insert(target.id)
      // The alert is what the person sees; this is what the log says at the same moment.
      logger.warning(
        "Webhook is failing persistently",
        metadata: [
          "url": .string(Redaction.url(target.url)),
          "failures": .stringConvertible(count),
        ])
      await alerts?.raise(
        UserAlert(
          severity: .warning,
          title: "A webhook has stopped responding",
          body: "\(Redaction.url(target.url)) has failed \(count) times in a row. "
            + "Events are still being delivered everywhere else.",
          source: "webhook",
          diagnostics: Diagnostics(
            code: "webhook.persistent_failure",
            domain: "Webhook",
            underlyingDescription: String(describing: error),
            context: [
              "url": .string(Redaction.url(target.url)),
              "consecutive_failures": .int(count),
            ]
          ),
          actions: [.openSettings(.webhooks)],
          dedupeKey: "webhook.failure.\(target.id)"
        )
      )
    }
  }

  // MARK: - The retry timer

  /// Makes sure something wakes when the earliest outbox is due.
  private func armWake() {
    guard isRetryTimerEnabled, !isStopped, let next = outboxes.nextWake else {
      wake?.cancel()
      wake = nil
      wakeAt = nil
      return
    }
    // Already waking at or before that moment.
    if wake != nil, let wakeAt, wakeAt <= next { return }
    wake?.cancel()
    wakeAt = next
    wake = Task { [weak self] in
      // `try?` because the only error is cancellation, which the guard below handles.
      try? await Task.sleep(until: next, clock: .continuous)
      guard !Task.isCancelled else { return }
      await self?.wakeFired()
    }
  }

  /// Starts a drain for every outbox that is due, each in its own task so one slow endpoint
  /// does not hold the others. Not children of the wake task: re-arming cancels that task,
  /// and a cancelled POST would be reported as a failure that never happened.
  private func wakeFired() {
    wake = nil
    wakeAt = nil
    for id in outboxes.takeDue(at: .now) {
      Task { [weak self] in await self?.drain(id) }
    }
    armWake()
  }

  /// When the outbox next sends, as a date the settings page can show.
  private func nextAttemptDate(_ id: Int64) -> Date? {
    let now = ContinuousClock.now
    guard let next = outboxes.nextAttempt(id, now: now) else { return nil }
    return Date().addingTimeInterval(now.duration(to: next).seconds)
  }

  // MARK: - Lifecycle

  /// Discards every waiting event and stops the timer. Called when the service stops, so a
  /// sink that is no longer registered does not go on posting. Returns how many events were
  /// waiting, for the log line that says so.
  public func stopRetrying() -> Int {
    isStopped = true
    wake?.cancel()
    wake = nil
    wakeAt = nil
    return outboxes.discardAll()
  }

  /// For tests: stops the timer, so the outboxes send only when `runDueRetries` says.
  func disableRetryTimer() {
    isRetryTimerEnabled = false
    wake?.cancel()
    wake = nil
    wakeAt = nil
  }

  /// For tests: sends from every outbox due at `now`, and returns when they have finished.
  func runDueRetries(at now: ContinuousClock.Instant) async {
    for id in outboxes.takeDue(at: now) {
      await drain(id)
    }
  }

  /// For tests: how many events are waiting for one endpoint.
  func waiting(for id: Int64) -> Int { outboxes.waiting(id) }
}

// MARK: - ntfy

/// A first-class ntfy sink.
///
/// Users do this through generic webhooks today, which means hand-building topic URLs and
/// getting no title, priority, or click action, so every notification arrives as a wall of
/// JSON. A real sink maps the event onto ntfy's actual header protocol.
public struct NtfyTarget: Sendable {
  public let serverURL: String
  public let topic: String
  public let accessToken: String?
  public let events: [String]

  public init(
    serverURL: String = "https://ntfy.sh",
    topic: String,
    accessToken: String? = nil,
    events: [String] = ["*"]
  ) {
    self.serverURL = serverURL
    self.topic = topic
    self.accessToken = accessToken
    self.events = events
  }

  var endpoint: String {
    serverURL.hasSuffix("/") ? "\(serverURL)\(topic)" : "\(serverURL)/\(topic)"
  }

  func matches(_ name: EventName) -> Bool {
    events.contains("*") || !name.webhookAliases.isDisjoint(with: Set(events))
  }
}

/// ntfy as a notification transport, not as a webhook.
///
/// ntfy is a Firebase REPLACEMENT: someone configuring it is leaving Google, not
/// subscribing a URL, so it routes with push and does not receive typing indicators and
/// FindMy bursts, which are exactly the two the reference keeps off push.
///
/// Its size limit, if the operator set one, is its own: ntfy's `message-size-limit` is
/// configurable and its docs warn that anything over 4 KB is "not recommended, and largely
/// untested". That is a different number from Firebase's and belongs here, not above.
public struct NtfyProvider: NotificationProvider {

  /// Static as well as a member; see `FirebaseProvider.providerID` for why.
  public static let identifier = "ntfy"
  public var providerID: String { Self.identifier }
  public var subscription: EventSubscription {
    // The topic's own event list, which the settings UI already exposes and which ships as
    // `*`. `.all` when it is, so the routing policy alone decides.
    target.events.contains("*")
      ? .all
      : .only(Set(EventName.webhookSubscribable.filter { target.matches($0) }))
  }

  private let target: NtfyTarget
  private let transport: any HTTPPosting
  private let logger: Logger

  public init(
    target: NtfyTarget,
    transport: any HTTPPosting = URLSessionPoster(),
    logger: Logger = Logger(label: "bluebubbles.ntfy")
  ) {
    self.target = target
    self.transport = transport
    self.logger = logger
  }

  /// A configured topic is always ready: ntfy needs no registration handshake and no token
  /// list, so there is nothing that can be absent the way FCM's devices can.
  public var isReady: Bool { get async { !target.topic.isEmpty } }

  public func send(_ event: ServerEvent) async throws {
    var headers = ["Content-Type": "text/plain; charset=utf-8"]
    headers["Title"] = Self.title(for: event)
    headers["Priority"] = event.priority == .high ? "high" : "default"
    headers["Tags"] = Self.tags(for: event)
    if let token = target.accessToken {
      headers["Authorization"] = "Bearer \(token)"
    }

    let started = ContinuousClock.now
    try await transport.post(
      url: target.endpoint,
      body: Data(Self.body(for: event).utf8),
      headers: headers,
      // `true`, unlike a webhook's default, and it is a different situation rather than an
      // inconsistency. An ntfy endpoint is typed into the settings window by the operator and
      // is a public relay by design (ntfy.sh redirects), so there is no per-endpoint switch to
      // hang this on and nothing about following one that the operator did not already choose
      // by naming that host. Webhooks are registrable over the API by anything holding the
      // password, which is the reason the default differs there.
      followRedirects: true
    )
    // No topic and no body: the topic is what lets anyone read the feed, and the body is
    // the message text.
    logger.debug(
      "ntfy notification sent",
      metadata: [
        "event": .string(event.name.rawValue),
        "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
      ])
  }

  /// A human title. The whole reason this is not a generic webhook.
  static func title(for event: ServerEvent) -> String {
    switch event.name {
    case .newMessage: "New message"
    case .updatedMessage: "Message updated"
    case .messageSendError: "Message failed to send"
    case .groupNameChange: "Group renamed"
    case .participantAdded: "Participant added"
    case .participantRemoved: "Participant removed"
    case .participantLeft: "Participant left"
    case .incomingFaceTime: "Incoming FaceTime call"
    case .serverUpdate: "Server update available"
    case .newServer: "Server address changed"
    case .scheduledMessageError: "Scheduled message failed"
    default: event.name.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
    }
  }

  static func tags(for event: ServerEvent) -> String {
    switch event.name {
    case .newMessage: "speech_balloon"
    case .messageSendError, .scheduledMessageError: "warning"
    case .incomingFaceTime: "telephone"
    case .serverUpdate: "arrow_up"
    default: "bell"
    }
  }

  /// The message text, preferring the actual message body over a JSON dump.
  ///
  /// Falls back to the serialized payload rather than to an empty string: an unrecognised
  /// event is still worth delivering, and a wall of JSON is at least actionable.
  static func body(for event: ServerEvent) -> String {
    if case .object(let object) = event.notificationPayload {
      if case .string(let text)? = object["text"], !text.isEmpty { return text }
    }
    let data = try? event.notificationPayload.serialize()
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? event.name.rawValue
  }
}

// MARK: - Transport

public protocol HTTPPosting: Sendable {
  /// - Parameter followRedirects: whether a 3xx may be followed. Part of the protocol rather
  ///   than a property of the poster, because it is a property of the TARGET: one server
  ///   delivers to every webhook, and each one carries its own answer.
  func post(
    url: String, body: Data, headers: [String: String], followRedirects: Bool
  ) async throws
}

extension HTTPPosting {
  public func post(url: String, body: Data, followRedirects: Bool = false) async throws {
    try await post(
      url: url, body: body, headers: ["Content-Type": "application/json"],
      followRedirects: followRedirects
    )
  }
}

public struct URLSessionPoster: HTTPPosting {

  private let timeout: TimeInterval

  public init(timeout: TimeInterval = 15) {
    self.timeout = timeout
  }

  public enum PostError: BBError {
    case invalidURL(String)
    case httpStatus(Int)
  }

  public func post(
    url: String, body: Data, headers: [String: String], followRedirects: Bool
  ) async throws {
    guard let target = URL(string: url) else { throw PostError.invalidURL(url) }

    var request = URLRequest(url: target, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = body
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }

    // `URLSession.shared` FOLLOWS REDIRECTS and has no way to be told not to: the decision is
    // a delegate's, and the shared session's delegate is not ours to set. So a target that
    // refuses redirects gets its own one-request session; one that allows them keeps the
    // shared session, which is the pooled, warmed-up path and what every webhook used before
    // this existed.
    guard !followRedirects else {
      try Self.check(try await URLSession.shared.data(for: request).1)
      return
    }

    let session = URLSession(
      configuration: .ephemeral, delegate: RedirectRefusing(), delegateQueue: nil
    )
    // Invalidated rather than left to deallocate: a session with a delegate holds a strong
    // reference to it, so dropping the last reference leaks both until the process exits.
    defer { session.finishTasksAndInvalidate() }
    try Self.check(try await session.data(for: request).1)
  }

  /// A 3xx reported as the failure it is, rather than followed.
  ///
  /// `nil` from the completion handler is how `URLSession` is told to stop and hand the
  /// redirect response back to the caller, so the 301/302 arrives here as an ordinary
  /// response and `check` refuses it for being outside 2xx. The delivery tracker then shows
  /// "HTTP 302" beside the webhook, which is the honest description of what happened and
  /// tells an operator exactly which switch to turn on.
  private final class RedirectRefusing: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  private static func check(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw PostError.httpStatus(http.statusCode)
    }
  }
}

extension URLSessionPoster.PostError {
  public var code: String {
    switch self {
    case .invalidURL: "webhook.invalid_url"
    case .httpStatus: "webhook.http_status"
    }
  }

  public var domain: String { "Webhooks" }

  public var title: String { "A webhook could not be delivered" }

  public var body: String {
    switch self {
    case .invalidURL(let url): "\(url) is not a URL this server can post to."
    case .httpStatus(let status): "The endpoint answered \(status)."
    }
  }

  public var context: [String: DiagnosticValue] {
    if case .httpStatus(let status) = self { return ["status": .int(status)] }
    return [:]
  }
}
