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

  public init(
    id: Int64, url: String, events: [String], codecs: Set<CodecIdentifier> = [.legacyV1],
    followRedirects: Bool = false
  ) {
    self.id = id
    self.url = url
    self.events = events
    self.codecs = codecs
    self.followRedirects = followRedirects
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

  public func accepts(_ event: ServerEvent) async -> Bool {
    await targets().contains { $0.matches(event.name) }
  }

  public func deliver(_ event: ServerEvent) async throws {
    let matching = await targets().filter { $0.matches(event.name) }
    guard !matching.isEmpty else { return }

    // Bounded concurrency rather than one task per target: a user with fifty webhooks
    // should not open fifty sockets at once on a machine this is meant to run on.
    await withTaskGroup(of: Void.self) { group in
      var running = 0
      for target in matching {
        if running >= 8 {
          await group.next()
          running -= 1
        }
        group.addTask { await self.post(event, to: target) }
        running += 1
      }
    }
  }

  private func post(_ event: ServerEvent, to target: WebhookTarget) async {
    let started = ContinuousClock.now
    do {
      // The same call the test send makes. A separate implementation here would mean
      // "Send Test" could pass while real delivery was broken.
      try await WebhookDelivery.send(
        event, to: target, negotiator: negotiator, transport: transport,
        projection: projection
      )
      await deliveries.record(
        id: target.id, url: target.url, event: event.name.rawValue, outcome: .delivered
      )
      alerted.remove(target.id)
      // The URL is redacted before it reaches a log, here and below: clients routinely
      // register webhook URLs with the server password in the query string.
      logger.debug(
        "Webhook delivered",
        metadata: [
          "url": .string(Redaction.url(target.url)),
          "event": .string(event.name.rawValue),
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
        ])

    } catch {
      let reason = WebhookDeliveryState.reason(for: error)
      let count = await deliveries.record(
        id: target.id, url: target.url, event: event.name.rawValue,
        outcome: .failed(reason)
      )

      logger.debug(
        "Webhook dispatch failed",
        metadata: [
          "url": .string(Redaction.url(target.url)),
          "event": .string(event.name.rawValue),
          "failures": .stringConvertible(count),
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
  }

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
