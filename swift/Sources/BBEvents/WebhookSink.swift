//  WebhookSink / NtfySink
//  Outbound HTTP delivery, written against CustomEventSink.
//
//  Both are deliberately implemented through the public extension surface rather than being
//  special-cased inside the bus. That is the standing proof the seam is expressive enough —
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

  public init(
    id: Int64, url: String, events: [String], codecs: Set<CodecIdentifier> = [.legacyV1]
  ) {
    self.id = id
    self.url = url
    self.events = events
    self.codecs = codecs
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

  /// Consecutive failures per target, and the last outcome for each — held in the tracker
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

    } catch {
      let count = await deliveries.record(
        id: target.id, url: target.url, event: event.name.rawValue,
        outcome: .failed(WebhookDeliveryState.reason(for: error))
      )

      // Redacted before it reaches a log. Clients routinely register webhook URLs with
      // the server password in the query string, so logging the raw URL writes that
      // secret to disk on every dispatch.
      logger.debug(
        "Webhook dispatch failed",
        metadata: [
          "url": .string(Self.redact(target.url)),
          "event": .string(event.name.rawValue),
          "failures": .stringConvertible(count),
        ])

      if count >= failuresBeforeAlert && !alerted.contains(target.id) {
        alerted.insert(target.id)
        await alerts?.raise(
          UserAlert(
            severity: .warning,
            title: "A webhook has stopped responding",
            body: "\(Self.redact(target.url)) has failed \(count) times in a row. "
              + "Events are still being delivered everywhere else.",
            source: "webhook",
            diagnostics: Diagnostics(
              code: "webhook.persistent_failure",
              domain: "Webhook",
              underlyingDescription: String(describing: error),
              context: [
                "url": .string(Self.redact(target.url)),
                "consecutive_failures": .int(count),
              ]
            ),
            actions: [.openSettings(section: "webhooks")],
            dedupeKey: "webhook.failure.\(target.id)"
          )
        )
      }
    }
  }

  /// Strips `password` and `guid` from a URL before logging it.
  static func redact(_ url: String) -> String {
    guard var components = URLComponents(string: url), let items = components.queryItems else {
      return url
    }
    components.queryItems = items.map { item in
      ["password", "guid", "token"].contains(item.name.lowercased())
        ? URLQueryItem(name: item.name, value: "***")
        : item
    }
    return components.string ?? url
  }
}

// MARK: - ntfy

/// A first-class ntfy sink.
///
/// Users do this through generic webhooks today, which means hand-building topic URLs and
/// getting no title, priority, or click action — so every notification arrives as a wall of
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

public struct NtfySink: CustomEventSink {

  public let id = SinkID.ntfy
  public let routing = SinkRouting.webhook
  public let projection = PayloadProjection.notification

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

  public func accepts(_ event: ServerEvent) async -> Bool {
    target.matches(event.name)
  }

  public func deliver(_ event: ServerEvent) async throws {
    var headers = ["Content-Type": "text/plain; charset=utf-8"]
    headers["Title"] = Self.title(for: event)
    headers["Priority"] = event.priority == .high ? "high" : "default"
    headers["Tags"] = Self.tags(for: event)
    if let token = target.accessToken {
      headers["Authorization"] = "Bearer \(token)"
    }

    try await transport.post(
      url: target.endpoint,
      body: Data(Self.body(for: event).utf8),
      headers: headers
    )
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
  func post(url: String, body: Data, headers: [String: String]) async throws
}

extension HTTPPosting {
  public func post(url: String, body: Data) async throws {
    try await post(url: url, body: body, headers: ["Content-Type": "application/json"])
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

  public func post(url: String, body: Data, headers: [String: String]) async throws {
    guard let target = URL(string: url) else { throw PostError.invalidURL(url) }

    var request = URLRequest(url: target, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = body
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }

    let (_, response) = try await URLSession.shared.data(for: request)
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
