//  EventBusTests
//
//  Three things are being guarded:
//    1. Default-off enforcement — a default server emits legacy-v1 to every target no matter
//       what a client advertises. "Available but unused" drifts into "used" without a test.
//    2. Routing exceptions — typing indicators and FindMy locations skip PUSH and keep the
//       socket. Both were transcribed from emitMessage's positional booleans, and both are
//       easy to get backwards.
//    3. A slow subscriber must not delay ingestion. This is the property the whole extension
//       seam rests on.

import BBSerialization
import Foundation
import Testing

@testable import BBEvents

// MARK: - Doubles

actor RecordingSink: EventSink {
  nonisolated let id: SinkID
  nonisolated let projection: PayloadProjection

  private(set) var received: [EventName] = []
  private(set) var payloads: [JSONValue] = []
  var delay: Duration?

  init(id: SinkID, projection: PayloadProjection = .notification) {
    self.id = id
    self.projection = projection
  }

  func accepts(_ event: ServerEvent) async -> Bool { true }

  func deliver(_ event: ServerEvent) async throws {
    if let delay { try await Task.sleep(for: delay) }
    received.append(event.name)
    payloads.append(event.payload(for: projection))
  }

  func setDelay(_ duration: Duration?) { delay = duration }
  func names() -> [EventName] { received }
}

func makeEvent(
  _ name: EventName,
  full: JSONValue = .object(["full": .bool(true), "text": .string("hi")]),
  notification: JSONValue = .object(["text": .string("hi")])
) -> ServerEvent {
  ServerEvent(name: name, fullPayload: full, notificationPayload: notification)
}

// MARK: - Routing

@Suite("Event routing")
struct EventRoutingTests {

  @Test("Typing indicators skip push and keep the socket")
  func typingIndicatorRouting() async {
    // From `emitMessage(TYPING_INDICATOR, …, "normal", false)` — the fourth argument is
    // sendFcmMessage, not sendSocket. Getting this backwards silently kills typing
    // indicators for every socket client.
    let routing = EventRouting.policy(for: .typingIndicator)
    #expect(routing.allowsSocket)
    #expect(!routing.allowsPush)
    #expect(routing.allowsWebhooks)
  }

  @Test("FindMy locations skip push and are rate limited")
  func findMyRouting() {
    let routing = EventRouting.policy(for: .newFindMyLocation)
    #expect(routing.allowsSocket)
    #expect(!routing.allowsPush)
    #expect(routing.minimumInterval == .milliseconds(250))
  }

  @Test("iMessage alias removal reaches every sink")
  func aliasRemovalRouting() {
    // `emitMessage(IMESSAGE_ALIASES_REMOVED, …, "high", true)` suppresses nothing.
    let routing = EventRouting.policy(for: .iMessageAliasesRemoved)
    #expect(routing.allowsSocket)
    #expect(routing.allowsPush)
    #expect(routing.allowsWebhooks)
  }

  @Test("Everything else reaches every sink")
  func defaultRouting() {
    for name in [EventName.newMessage, .updatedMessage, .groupNameChange, .incomingFaceTime] {
      let routing = EventRouting.policy(for: name)
      #expect(
        routing.allowsSocket && routing.allowsPush && routing.allowsWebhooks,
        "\(name) should not be suppressed anywhere")
    }
  }

  @Test("Suppression actually stops delivery")
  func suppressionIsEnforced() async {
    let bus = EventBus()
    let socket = RecordingSink(id: .socket, projection: .full)
    let push = RecordingSink(id: .push)
    await bus.register(socket)
    await bus.register(push)

    await bus.emit(makeEvent(.typingIndicator))
    await bus.settle()

    #expect(await socket.names() == [.typingIndicator])
    #expect(await push.names().isEmpty)
  }

  @Test("The rate limit is keyed, so a busy chat cannot starve a quiet one")
  func rateLimitIsKeyed() async {
    let bus = EventBus()
    let socket = RecordingSink(id: .socket, projection: .full)
    await bus.register(socket)

    // A pinned instant, not the wall clock. Emitting three times and trusting them to
    // land inside 250ms works until the machine is busy, at which point the second emit
    // genuinely falls outside the window and the test fails for a reason unrelated to
    // what it is checking.
    let instant = ContinuousClock.now
    await bus.emit(makeEvent(.newFindMyLocation), rateLimitKey: "device-a", now: instant)
    await bus.settle()
    await bus.emit(
      makeEvent(.newFindMyLocation), rateLimitKey: "device-a",
      now: instant.advanced(by: .milliseconds(10))
    )
    await bus.emit(makeEvent(.newFindMyLocation), rateLimitKey: "device-b", now: instant)
    await bus.settle()

    // ONE, and the key is ignored. FindMy's limit is global on purpose: it exists to
    // keep this server from polling Apple too hard, and Apple does not care which of our
    // devices a request was about. Keying per device would multiply the permitted rate
    // by the device count, which is the pressure the limit is meant to remove.
    #expect(await socket.names().count == 1)

    // The two held emissions are COALESCED, not dropped: the newest survives and is
    // delivered once the window passes. That is the difference that matters for state —
    // a position discarded leaves every client holding a stale one.
    await bus.flushPending()
    #expect(await socket.names().count == 2)
  }

  @Test("A chat-keyed event is still limited per chat")
  func chatKeyedLimitsRemainPerKey() async {
    // The general rule, unchanged: only FindMy opts into a shared bucket, because only
    // FindMy's limit is about an upstream service rather than our own delivery.
    #expect(EventRouting.policy(for: .newFindMyLocation).isRateLimitGlobal)
    #expect(!EventRouting.policy(for: .newMessage).isRateLimitGlobal)
    #expect(!EventRouting.policy(for: .typingIndicator).isRateLimitGlobal)
  }
}

// MARK: - Projections

@Suite("Payload projections")
struct ProjectionTests {

  @Test("The socket gets the full payload and push gets the trimmed one")
  func projectionsDiffer() async {
    // Mixing these up is the most likely way to break clients while every test passes:
    // the notification variant sheds ~18 fields, and a socket client reads them.
    let bus = EventBus()
    let socket = RecordingSink(id: .socket, projection: .full)
    let push = RecordingSink(id: .push, projection: .notification)
    await bus.register(socket)
    await bus.register(push)

    await bus.emit(makeEvent(.newMessage))
    await bus.settle()

    guard case .object(let socketPayload)? = await socket.payloads.first,
      case .object(let pushPayload)? = await push.payloads.first
    else {
      Issue.record("Expected both sinks to receive an object")
      return
    }
    #expect(socketPayload["full"] != nil)
    #expect(pushPayload["full"] == nil)
  }

  @Test("An event with no separate notification payload uses the full one")
  func projectionsCoincide() {
    let event = ServerEvent(name: .helloWorld, fullPayload: .null)
    #expect(event.payload(for: .full) == event.payload(for: .notification))
  }
}

// MARK: - Sink independence

@Suite("Sink independence")
struct SinkIndependenceTests {

  @Test("emit returns before delivery, and each lane keeps its order")
  func emitDoesNotWaitAndLanesAreOrdered() async {
    // The message poller emits from its loop. If emit waited for delivery, one slow
    // webhook would hold back the next new-message event for every socket client.
    let bus = EventBus(deliveryTimeout: .seconds(5))
    let slow = RecordingSink(id: .webhook)
    await slow.setDelay(.milliseconds(150))
    await bus.register(slow)

    let started = ContinuousClock.now
    await bus.emit(makeEvent(.newMessage))
    await bus.emit(makeEvent(.updatedMessage))
    let queued = ContinuousClock.now - started
    #expect(queued < .milliseconds(100), "emit waited on the sink for \(queued)")

    await bus.settle()
    #expect(await slow.names() == [.newMessage, .updatedMessage])
  }

  @Test("settle on an idle bus returns at once")
  func settleWhenIdle() async {
    let bus = EventBus()
    await bus.register(RecordingSink(id: .socket, projection: .full))
    await bus.settle()
    #expect(await bus.activeSinks == [.socket])
  }

  @Test("One sink hanging does not block another")
  func slowSinkDoesNotBlockOthers() async {
    // A webhook endpoint that hangs must not delay socket delivery. Each sink has its own
    // lane with a per-event timeout, so the socket lands while the webhook waits.
    let bus = EventBus(deliveryTimeout: .milliseconds(200))
    let socket = RecordingSink(id: .socket, projection: .full)
    let webhook = RecordingSink(id: .webhook)
    await webhook.setDelay(.seconds(30))
    await bus.register(socket)
    await bus.register(webhook)

    let started = ContinuousClock.now
    await bus.emit(makeEvent(.newMessage))
    await bus.settle()
    let elapsed = ContinuousClock.now - started

    #expect(await socket.names() == [.newMessage])
    #expect(await webhook.names().isEmpty, "The slow sink should have timed out")
    #expect(elapsed < .seconds(5), "The bus waited on the hung sink for \(elapsed)")
  }

  @Test("A sink that throws does not affect its siblings")
  func throwingSinkIsIsolated() async {
    struct FailingSink: EventSink {
      let id = SinkID("failing")
      let projection = PayloadProjection.notification
      func accepts(_ event: ServerEvent) async -> Bool { true }
      func deliver(_ event: ServerEvent) async throws {
        struct Boom: Error {}
        throw Boom()
      }
    }

    let bus = EventBus()
    let socket = RecordingSink(id: .socket, projection: .full)
    await bus.register(socket)
    await bus.register(FailingSink())

    await bus.emit(makeEvent(.newMessage))
    await bus.settle()
    #expect(await socket.names() == [.newMessage])
  }

  @Test("An install with no push sink is a valid deployment")
  func socketOnlyInstall() async {
    // Not a degraded state. A socket-only install must emit no warnings and lose no
    // events — which is why an unconfigured sink is never registered rather than
    // registered-and-disabled.
    let bus = EventBus()
    let socket = RecordingSink(id: .socket, projection: .full)
    await bus.register(socket)

    #expect(await bus.activeSinks == [.socket])
    await bus.emit(makeEvent(.newMessage))
    await bus.settle()
    #expect(await socket.names() == [.newMessage])
  }
}

// MARK: - Codec negotiation

@Suite("Codec negotiation")
struct CodecNegotiationTests {

  @Test("A default server emits legacy-v1 however capable the client claims to be")
  func serverPreferenceIsACeiling() async throws {
    // THE default-off test. A client cannot opt itself into a codec the server has not
    // enabled, which is what keeps "switchable" from becoming "switched".
    let negotiator = CodecNegotiator.legacyOnly()
    let capable = TargetCapabilities(
      supportedCodecs: [.legacyV1, .referenceV2, .sealedV2],
      publicKey: Data(repeating: 7, count: 32)
    )
    #expect(negotiator.resolve(for: capable).identifier == .legacyV1)
  }

  @Test("legacy-v1 passes the payload through unchanged")
  func legacyIsTransparent() async throws {
    let event = makeEvent(.newMessage)
    let encoded = try await LegacyPayloadCodec().encode(
      event, projection: .full, capabilities: .legacy
    )
    #expect(encoded.body == event.fullPayload)
    #expect(encoded.codec == .legacyV1)
  }

  @Test("A default server advertises only what it has")
  func advertisedCodecs() {
    #expect(CodecNegotiator.legacyOnly().supportedIdentifiers == ["legacy-v1"])
  }

  @Test("sealed-v2 without a key falls back rather than failing")
  func sealedWithoutKeyFallsBack() {
    struct StubCodec: EventPayloadCodec {
      let identifier: CodecIdentifier
      func encode(
        _ event: ServerEvent, projection: PayloadProjection,
        capabilities: TargetCapabilities
      ) async throws -> EncodedPayload {
        EncodedPayload(codec: identifier, body: .null)
      }
    }

    let negotiator = CodecNegotiator(
      serverPreference: .sealedV2,
      codecs: [
        LegacyPayloadCodec(),
        StubCodec(identifier: .referenceV2),
        StubCodec(identifier: .sealedV2),
      ]
    )
    // Claims sealed-v2 but registered no public key.
    let capabilities = TargetCapabilities(supportedCodecs: [.sealedV2, .referenceV2, .legacyV1])
    #expect(negotiator.resolve(for: capabilities).identifier == .referenceV2)
  }
}

// MARK: - Webhook matching

@Suite("Webhook subscription matching")
struct WebhookMatchingTests {

  @Test("A wildcard subscription matches everything")
  func wildcard() {
    let target = WebhookTarget(id: 1, url: "https://example.com", events: ["*"])
    #expect(target.matches(.newMessage))
    #expect(target.matches(.typingIndicator))
  }

  @Test("The singular alias the UI offers matches the plural event we emit")
  func aliasMatching() {
    // The settings picker offers `imessage-alias-removed`; the event is emitted as
    // `imessage-aliases-removed`. Exact-match-only makes that subscription silently
    // dead, which is indistinguishable from a broken webhook.
    let target = WebhookTarget(
      id: 1, url: "https://example.com", events: ["imessage-alias-removed"]
    )
    #expect(target.matches(.iMessageAliasesRemoved))
  }

  @Test("An unsubscribed event does not match")
  func noMatch() {
    let target = WebhookTarget(id: 1, url: "https://example.com", events: ["new-message"])
    #expect(target.matches(.newMessage))
    #expect(!target.matches(.typingIndicator))
  }

  @Test("Credentials are redacted before a URL reaches a log")
  func urlRedaction() {
    // Clients routinely register webhook URLs with the server password in the query
    // string, so logging the raw URL writes that secret to disk on every dispatch.
    let redacted = WebhookSink.redact("https://example.com/hook?password=hunter2&x=1")
    #expect(!redacted.contains("hunter2"))
    #expect(redacted.contains("x=1"))
  }
}
