//  FaceTimeBridge+Calls
//  The Mac's own calls: dialling out (Flow B), answering and leaving (Flow C), silencing the
//  Mac on a call it is only holding open for a hand-off, and reading a call's state back.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - Outbound call (Flow B)

  /// Places an outgoing FaceTime call so the target's device rings.
  ///
  /// Three steps: build the `TUDialRequest` (`makeDialRequest`), hand it to the call
  /// center through whichever completion selector this release has (`performDial`), then
  /// find the resulting call and silence the Mac's side of it.
  static func dial(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    try requireFaceTimeHost()
    let center = try callCenter()
    let dialRequest = try makeDialRequest(request, on: center)

    // Diagnostics for the failure path. `validityErrors` is TelephonyUtilities' own
    // verdict on the request and names the exact refusal, far better than the opaque
    // `TUDialRequestErrorDomain` code the dial returns.
    //
    // NOTE: `-[TUHandle description]` REDACTS the address (it prints an opaque `u:…`
    // token), so a logged handle looking mangled is a privacy feature, not a bug; the
    // `value` property holds the real address. Measured; do not "fix" the constructors
    // based on the description alone.
    let validity =
      (try? IMCoreRuntime.send(dialRequest, "validityErrors"))
      .map { String(describing: $0) } ?? "none"
    let requestDescription = (try? IMCoreRuntime.string(dialRequest, "description")) ?? nil

    // The calls that existed BEFORE the dial, so the fallback below can tell the one this
    // dial made from one that was already up. Nil when the list cannot be read, which
    // disables the fallback rather than guessing.
    let callsBeforeDial = (try? IMCoreRuntime.send(center, "currentCalls"))
      .map { Set(collection($0).compactMap(callUUID(of:))) }

    let dialed = try await performDial(dialRequest, on: center)

    // The completion does not always hand the call back, but the call is on the center
    // either way. Only a call that APPEARED during the dial is taken, and only when it is
    // the only one: `currentCalls.last` could be an unrelated call already in progress,
    // and the hand-off would then silence, report and later end somebody else's call.
    let call = dialed.object ?? callsBeforeDial.flatMap { newCall(on: center, excluding: $0) }
    guard let call else {
      let why = dialed.failure.map { "; \($0)" } ?? ""
      throw PrivateAPIError.rejectedByMessages(
        reason: "the dial produced no call\(why). validityErrors=\(validity) "
          + "request=\(requestDescription ?? "nil")"
      )
    }
    // Silence the Mac immediately: it is only holding the call open for the hand-off.
    silenceLocalParticipant(call)
    return decodeCall(call)
  }

  /// A call's `callUUID`, or nil when it has none to compare by.
  private static func callUUID(of call: AnyObject) -> String? {
    guard let uuid = (try? IMCoreRuntime.string(call, "callUUID")) ?? nil, !uuid.isEmpty
    else { return nil }
    return uuid
  }

  /// The single call on the center whose UUID is not in `existing`, or nil when there is
  /// none or more than one: two new calls cannot be told apart, and picking one is the
  /// guess this exists to avoid.
  private static func newCall(on center: AnyObject, excluding existing: Set<String>)
    -> AnyObject?
  {
    let calls = collection(try? IMCoreRuntime.send(center, "currentCalls"))
    let appeared = calls.filter { call in
      callUUID(of: call).map { !existing.contains($0) } ?? false
    }
    return appeared.count == 1 ? appeared[0] : nil
  }

  /// A `TUDialRequest` for the FaceTime provider, with its handles and media set.
  private static func makeDialRequest(
    _ request: FaceTimeStartRequest, on center: AnyObject
  ) throws -> AnyObject {
    guard let dialType = IMCoreRuntime.lookUpClass("TUDialRequest") else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "dialFaceTime", requires: "TUDialRequest"
      )
    }
    // `-[TUDialRequest init]` is REFUSED: TelephonyUtilities asserts
    // "Don't call -[TUDialRequest init], call designated initializer instead." (measured).
    //
    // The right designated initializer is `initWithProvider:`, NOT `initWithService:`
    // with a guessed integer. A guessed service produced a request with no provider, and
    // TelephonyUtilities' own `validityErrors` named it exactly:
    //   Code=6 "Requested video for a provider which doesn't support it"
    //   Code=8 "Provider does not support the specified handle type"
    // Both are provider complaints. `TUCallProviderManager.faceTimeProvider` is the real
    // FaceTime provider, and asking for it removes the guesswork entirely.
    // `TUCallProviderManager` has no singleton, but the call center already holds one,
    // and it is the SAME manager FaceTime.app itself dials through, so its providers are
    // the real, registered ones rather than a detached copy.
    guard let manager = try? IMCoreRuntime.send(center, "providerManager") else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "TUCallCenter has no providerManager"
      )
    }
    guard let provider = try? IMCoreRuntime.send(manager, "faceTimeProvider") else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "no FaceTime provider; the account may not be signed in to FaceTime"
      )
    }

    // `initWithProvider:`, allocated and initialised together; see `IMCoreRuntime.create`.
    // An explicit nil would travel as `NSNull()`, which is why this no longer needs the
    // typed-IMP initialiser it used to call.
    guard
      let request0 = try? IMCoreRuntime.create(dialType, "initWithProvider:", [provider])
    else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "TUDialRequest rejected initWithProvider:"
      )
    }

    // Handles are set AFTER `initWithProvider:`: the initializer builds a fresh request,
    // so anything set on the allocation beforehand is discarded. Getting this order wrong
    // produced `handles=(null)` and validity Code=7 ("destinationID and contactIdentifier
    // are both nil/empty").
    let handles = request.addresses.compactMap(makeHandle)
    guard !handles.isEmpty else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "could not build a TUHandle for "
          + request.addresses.joined(separator: ", ")
      )
    }
    // Both the singular `handle` and the `handles` set: which one the dial path reads is
    // not documented, and setting only one has produced a silently-declined request.
    if let first = handles.first {
      _ = try? IMCoreRuntime.invoke(request0, "setHandle:", [first])
    }
    try IMCoreRuntime.invoke(request0, "setHandles:", [NSSet(array: handles)])
    try IMCoreRuntime.callBool(request0, "setVideo:", request.video)
    return request0
  }

  /// Hands the request to the call center and waits for its completion. The reply holds
  /// the call the completion returned, if any, and the error where the selector reports one.
  private static func performDial(
    _ dialRequest: AnyObject, on center: AnyObject
  ) async throws -> CompletionReply {
    // TWO GENERATIONS of the dial, and the difference is the completion block:
    //
    //   26        -dialWithRequest:completionWithError:   block is (call, error)
    //   14, 15    -dialWithRequest:completion:            block is (call)
    //
    // Both releases below 26 have only the older one, so calling the newer unconditionally
    // meant outgoing calls failed outright on two of the three supported releases
    // (`docs/MACOS_COMPATIBILITY.md` §3b). Newest first, like every other ladder here.
    //
    // WHAT THE OLDER PATH LOSES is the error object, and nothing else. That costs only the
    // `; <reason>` clause in the failure message below; `validityErrors`, which is
    // TelephonyUtilities' own verdict on the request and the more useful diagnostic anyway,
    // is read before the dial and is unaffected. A block declared with FEWER parameters than
    // the caller passes is safe on arm64: the extra argument stays in its register and is
    // ignored. The reverse would not be, which is why the older path does not simply reuse
    // the two-argument shape.
    let (selector, shape) = try IMCoreRuntime.requireResponding(
      center,
      among: [
        ("dialWithRequest:completionWithError:", CompletionShape.objectAndError),
        ("dialWithRequest:completion:", CompletionShape.object),
      ])
    return await callAwaitingCompletion(
      center, selector, leading: [dialRequest], shape: shape)
  }

  /// Mutes the Mac's microphone and stops its camera on a call it is only HOLDING OPEN.
  ///
  /// During a hand-off the Mac is a genuine participant: until the client joins and the Mac
  /// drops out, the other party sees the Mac's camera and hears its microphone. That window
  /// is short but it is a live audio/video feed from an unattended computer, usually in
  /// someone's home, so it is closed immediately rather than tolerated.
  ///
  /// Note this does NOT make the call audio-only: it is still a video call, and the client
  /// that joins sends its own camera normally. Only the Mac's uplink is silenced.
  ///
  /// Best-effort: failing to mute costs privacy, not correctness, so it never fails the
  /// call. It is LOGGED, though, because a live microphone on an unattended Mac is the one
  /// failure here somebody needs to be able to find afterwards. `silence(callUUID:)` is
  /// the path that reports the resulting state to the server. `setMuted:` returns a BOOL
  /// that is ignored; `callBool` casts to a void-returning signature, which is safe here
  /// because the result simply stays in the return register.
  static func silenceLocalParticipant(_ call: AnyObject) {
    for (selector, value) in [("setMuted:", true), ("setIsSendingVideo:", false)] {
      do {
        try IMCoreRuntime.callBool(call, selector, value)
      } catch {
        BlueBubblesFaceTimeHelper.log.info(
          "Could not silence the Mac on a held call (\(selector)): \(error)")
      }
    }
  }

  /// Mutes a call by UUID and REPORTS the resulting state.
  ///
  /// Applying mute at dial time does not stick: the call is still `outgoing` (ringing) and
  /// the media session does not exist yet, so the setters are applied to a call that has no
  /// uplink to mute and are lost when it connects. MEASURED: the Mac's camera and
  /// microphone were live for the callee despite muting at dial.
  ///
  /// So this is re-assertable and idempotent: the hand-off watcher calls it on every poll
  /// until the Mac leaves, which covers the moment the call actually connects. It returns
  /// what the call reports afterwards so a caller can see whether it took.
  static func silence(callUUID: String) async throws -> (muted: Bool, sendingVideo: Bool) {
    try requireFaceTimeHost()
    let center = try callCenter()
    guard let call = try IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
      throw PrivateAPIError.rejectedByMessages(reason: "no FaceTime call \(callUUID)")
    }
    silenceLocalParticipant(call)
    return (
      muted: (try? IMCoreRuntime.bool(call, "isMuted")) ?? false,
      sendingVideo: (try? IMCoreRuntime.bool(call, "isSendingVideo")) ?? true
    )
  }

  // MARK: - Incoming call control (Flow C)

  static func answer(callUUID: String) async throws {
    try requireFaceTimeHost()
    let center = try callCenter()
    guard let call = try IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
      throw PrivateAPIError.rejectedByMessages(reason: "no FaceTime call \(callUUID) to answer")
    }
    // `answerOrJoinCall:` covers both a ringing 1:1 and a link conversation.
    try IMCoreRuntime.invoke(center, "answerOrJoinCall:", [call])
    // Same reasoning as the dial path: the Mac answered on a client's behalf and is only
    // holding the call until that client joins by link.
    silenceLocalParticipant(call)
  }

  static func leave(callUUID: String) async throws {
    try requireFaceTimeHost()
    let center = try callCenter()
    // `try`: only a call that is not there is "already gone". A lookup that FAILED used to
    // read the same, so the Mac could stay in a call, microphone live, while the log said it
    // had left.
    guard let call = try IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
      // Already gone is success: the goal is "the Mac is not in this call."
      return
    }
    try IMCoreRuntime.invoke(center, "disconnectCall:", [call])
  }

  // MARK: - Reading calls

  /// Where a call is now, or `.disconnected` when TelephonyUtilities no longer has it.
  ///
  /// A call that has ENDED is simply absent from the call centre; there is no tombstone,
  /// so "not found" and "disconnected" are the same answer, and reporting it as
  /// `.disconnected` lets a caller stop watching rather than poll a call that will never
  /// change again.
  static func callStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    _ = try await ensureClient()
    let center = try callCenter()
    guard let call = try IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
      return .disconnected
    }
    return FaceTimeCallStatus(raw: (try? IMCoreRuntime.integer(call, "callStatus")) ?? 0)
  }

  /// Every call the Mac is in.
  ///
  /// `currentCalls` is TelephonyUtilities' own list, so it sees calls this server knows
  /// nothing about, which is the point: after a server restart the Mac can still be sitting
  /// in a call whose hand-off watcher died with the old process.
  static func activeCalls() async throws -> [FaceTimeCall] {
    _ = try await ensureClient()
    let center = try callCenter()
    let calls = collection(try? IMCoreRuntime.send(center, "currentCalls"))
    return calls.map(decodeCall).filter { !$0.callUUID.isEmpty }
  }

  // MARK: - Call decoding

  static func decodeCall(_ call: AnyObject) -> FaceTimeCall {
    let uuid = ((try? IMCoreRuntime.string(call, "callUUID")) ?? nil) ?? ""
    let status = (try? IMCoreRuntime.integer(call, "callStatus")) ?? 0
    let handleValue = (try? IMCoreRuntime.send(call, "handle"))
      .flatMap { ((try? IMCoreRuntime.string($0, "value")) ?? nil) }
    let group = (try? IMCoreRuntime.send(call, "conversationGroupUUID"))
      .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil }
    return FaceTimeCall(
      callUUID: uuid,
      status: FaceTimeCallStatus(raw: status),
      handle: handleValue.map {
        FaceTimeHandle(
          value: $0, displayName: (try? IMCoreRuntime.string(call, "displayName")) ?? nil
        )
      },
      groupUUID: group,
      isVideo: (try? IMCoreRuntime.bool(call, "isSendingVideo")) ?? true,
      callerIDBlocked: (try? IMCoreRuntime.bool(call, "callerIDBlocked")) ?? false
    )
  }
}
