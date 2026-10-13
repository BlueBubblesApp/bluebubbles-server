//  PrivateAPITransport
//  The seam between the server and whatever is running inside Messages.app.
//
//  ONE implementation: `SocketTransport`, a Unix-domain socket inside Messages' own container
//  with the peer verified by audit token against Messages' code signature.
//
//  Deliberately one, not two. A sandboxed Messages cannot reach a Unix socket OUTSIDE its
//  container: a narrower statement than "cannot reach a Unix socket", and the reason the
//  socket lives inside it. The loopback TCP alternative cannot identify its peer, so any
//  local process could connect and drive the Private API; not having one closes that rather
//  than defending it.
//
//  The protocol is kept as a protocol anyway. It is the seam a test double substitutes at,
//  and the helper transport is exactly the kind of thing that should be swappable without
//  the client above it noticing. See `.claude/docs/private-api.md`.

import BBCore
import BBPrivateAPIContract
import Foundation
import Logging

/// One request/response exchange with a helper.
public protocol PrivateAPITransport: Actor {
  // Declared `async` because a transport may have to ask something else: a test double
  // records, a future implementation might aggregate. An actor's ordinary isolated
  // property still satisfies this.
  var isConnected: Bool { get async }
  /// Identifiers of the helpers registered, keyed by bundle identifier.
  var connectedProcesses: Set<String> { get async }

  func start() async throws
  func stop() async

  /// Sends an action and waits for its reply.
  @discardableResult
  func request(action: String, data: WireJSON, timeout: Duration) async throws -> WireJSON?

  /// Sends an action to a SPECIFIC helper, by the bundle id it registered with, and waits.
  ///
  /// This is the routing seam for a multi-helper install: a FaceTime action has to reach the
  /// FaceTime-injected helper, not whichever helper happened to register most recently. The
  /// default implementation ignores `process`: a transport with a single helper, or a test
  /// double, has nowhere else to route, so only `SocketTransport` overrides it, and a
  /// nil `process` keeps the existing most-recent behaviour.
  @discardableResult
  func request(
    action: String, data: WireJSON, timeout: Duration, process: String?
  ) async throws -> WireJSON?

  /// Sends an action without waiting. Used for fire-and-forget actions the helper does not
  /// acknowledge.
  func send(action: String, data: WireJSON) async throws

  /// Inbound events, already decoded.
  var events: AsyncStream<PrivateAPIEvent> { get }
}

extension PrivateAPITransport {
  /// Two minutes, matching the current `TransactionPromise` timeout. Long because a send
  /// with a large attachment genuinely can take that long, and a spurious timeout would
  /// produce a duplicate message on retry.
  public static var defaultTimeout: Duration { .seconds(120) }

  @discardableResult
  public func request(action: String, data: WireJSON) async throws -> WireJSON? {
    try await request(action: action, data: data, timeout: Self.defaultTimeout)
  }

  /// Default routing: ignore the target. Overridden by `SocketTransport`.
  @discardableResult
  public func request(
    action: String, data: WireJSON, timeout: Duration, process: String?
  ) async throws -> WireJSON? {
    try await request(action: action, data: data, timeout: timeout)
  }

  /// Targeted request at the default timeout.
  @discardableResult
  public func request(
    action: String, data: WireJSON, process: String?
  ) async throws -> WireJSON? {
    try await request(
      action: action, data: data, timeout: Self.defaultTimeout, process: process
    )
  }

  // MARK: - Typed vocabulary
  //
  // The string overloads above stay: they are the wire, and the frame decoder deals in raw
  // names. Everything that ORIGINATES a command goes through these instead, so an action
  // that no helper implements is a compile error rather than a rejection at runtime.

  /// Deliberately UNtargeted, matching what these call sites did as strings.
  ///
  /// Naming `HelperHost.messages` here would be the obvious tidy-up and is a behaviour
  /// change, not a typing one: a targeted write fails outright when the named helper has not
  /// yet sent its registration ping, where the untargeted path falls back to the newest
  /// connection. That trade is worth making (with FaceTime also connected, "newest" can be
  /// the wrong helper) but it belongs in a change that can be judged on its own.
  @discardableResult
  public func request(
    action: MessagesHelperAction,
    data: WireJSON,
    timeout: Duration = Self.defaultTimeout
  ) async throws -> WireJSON? {
    try await request(action: action.rawValue, data: data, timeout: timeout)
  }

  /// Routed to the FaceTime helper by the action's type.
  ///
  /// A `process:` argument at every FaceTime call site would make "send a FaceTime command
  /// to the Messages helper" a plausible typo. It is not expressible here.
  @discardableResult
  public func request(
    action: FaceTimeHelperAction,
    data: WireJSON,
    timeout: Duration = Self.defaultTimeout
  ) async throws -> WireJSON? {
    try await request(
      action: action.rawValue, data: data, timeout: timeout, process: HelperHost.faceTime
    )
  }
}

// MARK: - Transactions

/// Correlates replies to requests by transaction id.
///
/// The helper answers out of order and on the same connection, so the id is the only thing
/// tying a reply to its caller. A transaction that never gets an answer must fail rather than
/// leak its waiter: an abandoned continuation is a permanently suspended task.
actor TransactionStore {

  private var pending: [String: OnceContinuation<WireJSON?>] = [:]
  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  /// Registers a transaction, THEN sends it, and suspends until it is answered, times out,
  /// or is cancelled.
  ///
  /// **The send happens in here, after registration, and the ordering is the whole point.**
  /// Writing the frame first and then awaiting the reply is a race the helper wins whenever
  /// it answers faster than this actor can record who is waiting: `resolve` drops a reply it
  /// has no continuation for, and the caller then waits out its entire timeout for an answer
  /// that has already arrived and been thrown away. The reply that arrives fastest is the one
  /// for an action the helper rejects immediately.
  ///
  /// Registering first makes it unrepresentable rather than unlikely: the continuation is in
  /// `pending` before the bytes leave, so there is no window in which a reply can find
  /// nothing to resume.
  ///
  /// `action` is carried only to name the timeout. Reporting the transaction id would say
  /// `timedOut(method: "3416CCD4-…")`, which identifies the attempt and not the operation.
  func await(
    id: String,
    action: String,
    timeout: Duration,
    send: @escaping @Sendable () async throws -> Void
  ) async throws -> WireJSON? {
    try await awaitContinuation(
      timeout: timeout,
      timeoutError: { PrivateAPIError.timedOut(method: action) },
      register: { waiter in
        // Not sent if the wait ended on the way here: the caller has already been told
        // it timed out or was cancelled, and a frame sent now would do the work anyway.
        guard await self.register(id: id, waiter: waiter) else { return }
        do {
          try await send()
        } catch {
          // The frame never left. Fail the transaction we just registered rather than
          // leaving it to time out over something already known.
          await self.fail(id: id, with: error)
        }
      },
      abandon: { waiter in await self.forget(id: id, waiter: waiter) }
    )
  }

  /// Stores `waiter` under `id`, or answers false when there is no longer anything to store.
  ///
  /// Registration hops to this actor from a separate task, so the caller can be cancelled
  /// or time out before it lands, which `FaceTimeCoordinator` cancelling a watcher
  /// mid-request does in practice. The waiter is already resolved by then; storing it would
  /// keep an entry nothing removes, and sending would do work nobody is waiting for.
  private func register(id: String, waiter: OnceContinuation<WireJSON?>) -> Bool {
    guard !waiter.isResolved else { return false }
    // A duplicate id would strand the first waiter forever. UUIDs make this impossible in
    // practice; failing loudly beats a silent hang if it ever happens.
    if let existing = pending.removeValue(forKey: id) {
      logger.error("Duplicate transaction id", metadata: ["id": .string(id)])
      existing.resume(throwing: PrivateAPIError.rejectedByMessages(reason: "duplicate transaction"))
    }
    pending[id] = waiter
    return true
  }

  /// Drops a transaction whose caller stopped waiting: it timed out or was cancelled.
  private func forget(id: String, waiter: OnceContinuation<WireJSON?>) {
    if pending[id] === waiter { pending[id] = nil }
  }

  func resolve(id: String, with value: WireJSON?) {
    guard let continuation = pending.removeValue(forKey: id) else {
      // The race the header describes, if it ever regresses: a reply with nobody waiting.
      logger.debug(
        "Reply for an unknown transaction",
        metadata: ["tx": .string(String(id.prefix(8)))])
      return
    }
    continuation.resume(returning: value)
  }

  func fail(id: String, with error: any Error) {
    // Nobody waiting means the transaction is already finished: answered, timed out or
    // cancelled. There is nothing left to tell.
    pending.removeValue(forKey: id)?.resume(throwing: error)
  }

  /// Fails everything outstanding. Called when the helper disconnects: those replies are
  /// never coming, and the callers are entitled to find out now rather than in two minutes.
  func failAll(with error: any Error) {
    let outstanding = pending
    pending.removeAll()
    if !outstanding.isEmpty {
      // One line: `HelperVocabularyTests` exempts log metadata by the `metadata:` token.
      logger.warning(
        "Failing \(outstanding.count) outstanding Private API requests",
        metadata: ["error": .string(Redaction.error(error))]
      )
    }
    for (_, waiter) in outstanding {
      waiter.resume(throwing: error)
    }
  }

  var count: Int { pending.count }
}

// MARK: - Wire shapes

/// What the server writes: `{"action": …, "data": {…}, "transactionId": …}` plus a newline.
struct HelperRequest: Encodable {
  let action: String
  let data: WireJSON
  let transactionId: String?
}

/// What the helper writes back.
///
/// Two disjoint shapes share one struct because that is how the protocol works: a message
/// carrying `transactionId` is a reply, and one carrying `event` is an unsolicited event.
struct HelperResponse: Decodable {
  let transactionId: String?
  let event: String?
  let error: WireJSON?
  let identifier: String?
  let data: WireJSON?
  let errorCode: String?
  let errorMethod: String?
  let errorRequires: String?
  /// Everything else, which is where the payload lives when `data` is absent.
  let remainder: [String: WireJSON]

  private static let reservedKeys: Set<String> = Set(
    [WireKey.transactionId, .error, .errorCode, .errorMethod, .errorRequires, .identifier]
      .map(\.rawValue))

  init(from decoder: any Decoder) throws {
    let object = try decoder.singleValueContainer().decode([String: WireJSON].self)
    transactionId = object[.transactionId]?.stringValue
    event = object[.event]?.stringValue
    error = object[.error]
    identifier = object[.identifier]?.stringValue
    data = object[.data]
    errorCode = object[.errorCode]?.stringValue
    errorMethod = object[.errorMethod]?.stringValue
    errorRequires = object[.errorRequires]?.stringValue
    remainder = object.filter { !Self.reservedKeys.contains($0.key) }
  }

  /// Whether this reply reports a failure.
  ///
  /// Matches `isNotEmpty(data?.error ?? "")`: an empty string is success, which is not the
  /// same as the key being absent and matters because the helper sends `"error": ""`.
  var failureReason: String? {
    guard let error, !error.isEmptyValue else { return nil }
    return error.stringValue ?? String(describing: error)
  }

  /// The failure as the case the helper threw, when this reply reports one. See
  /// `PrivateAPIError.WireCode`.
  var failure: PrivateAPIError? {
    guard let reason = failureReason else { return nil }
    return PrivateAPIError(
      wireCode: errorCode,
      reason: reason,
      method: errorMethod,
      requires: errorRequires)
  }

  /// The payload, following `readTransactionData` exactly.
  ///
  /// A non-empty `data` key wins. Otherwise the reserved keys are stripped and whatever
  /// remains *is* the payload, and if nothing remains, the result is nil rather than an
  /// empty object. Reproduced rather than tidied, because clients of the helper depend on
  /// which of those two they get.
  var result: WireJSON? {
    if let data, !data.isEmptyValue { return data }
    // `event` is not a reserved key in the reference, so it survives the
    // strip. Kept identical on purpose.
    let stripped = remainder
    return stripped.isEmpty ? nil : .object(stripped)
  }
}
