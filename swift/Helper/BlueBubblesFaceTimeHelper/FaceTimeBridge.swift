//  FaceTimeBridge
//  FaceTime against TelephonyUtilities, from inside FaceTime.app.
//
//  WHERE THIS RUNS, AND WHY IT IS A DIFFERENT HOST
//  Everything else in this helper runs inside Messages.app and drives IMCore. FaceTime's call
//  machinery (`TUCallCenter`, `TUConversationManagerXPCClient`) is registered with the call
//  daemons by **FaceTime.app**, not Messages — so these calls only mean anything when the
//  helper is injected into `com.apple.FaceTime`. The same dylib serves both hosts; the server
//  injects it into FaceTime.app for FaceTime features and routes FaceTime actions to that
//  connection (see the transport's per-process routing).
//
//  THE FINDING THIS FILE IS BUILT AROUND (docs/headers/FACETIME.md)
//  The shipping Objective-C FaceTime helper "almost never works," and the reason is not the
//  selectors — it is the XPC client lifecycle. `TUConversationManagerXPCClient` has no
//  `sharedInstance`; it must be REGISTERED and have its INITIAL STATE fetched before
//  `activeConversations` / `activatedConversationLinks` are real, and it must re-register when
//  the daemon says so. The old helper `alloc/init`s a throwaway client inline on every call
//  and reads immediately, so those collections are empty and completions are torn down before
//  they fire. This file holds ONE long-lived client instead, registered and state-synced, and
//  drives everything through it.
//
//  UNTESTABLE HERE. Every call below needs FaceTime.app running with the dylib injected, which
//  needs SIP off — it cannot run under `swift test`. `IMCoreRuntime` keeps a moved selector
//  from crashing the host; `FaceTimeSelectorTests` pins the selector names against the live
//  runtime. Behaviour is validated on a real Mac.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperObjC
import HelperShared
import ObjectiveC

@MainActor
enum FaceTimeBridge {

  // MARK: - The long-lived conversation client

  /// The one registered `TUConversationManagerXPCClient`, held for the helper's lifetime.
  ///
  /// This is the whole fix. It is created once, registered, its initial state fetched, and
  /// its delegate installed; every link and member operation goes through it. Reading it
  /// before it has initial state returns empty collections — which is exactly the bug the
  /// throwaway-per-call approach ships — so `ensureClient()` blocks new callers only until
  /// the first registration completes, then reuses it.
  private static var conversationClient: AnyObject?
  private static var clientReady = false
  private static var delegateShim: FaceTimeDelegateShim?

  /// Emits an event frame to the server. Set by `HelperMain` when the FaceTime host starts.
  nonisolated(unsafe) static var emit: (@Sendable (String, [String: Any]) -> Void)?

  /// FaceTime.app's bundle identifier — the only host these calls are valid in.
  static let faceTimeBundleID = "com.apple.FaceTime"

  /// `TUDialRequest`'s service enum. 0 is telephony; FaceTime video and audio are 1 and 2.
  /// Probed at runtime rather than assumed — see `dial`, which reports the value back when
  /// the initializer refuses it, so a wrong constant names itself instead of failing blind.
  static let faceTimeVideoService = 1
  static let faceTimeAudioService = 2

  /// Refuses to touch TelephonyUtilities anywhere but FaceTime.app.
  ///
  /// This is a HARD guard, not an optimisation. `TUConversationManagerXPCClient` and
  /// `TUCallCenter` are backed by an XPC registration that only FaceTime.app holds;
  /// constructing and registering them in any other process — Messages, or a test host —
  /// traps inside TelephonyUtilities and takes the process down. The same dylib is injected
  /// into both Messages and FaceTime, so every FaceTime entry point checks the host first
  /// and reports `unavailableOnThisOS` (a recognised-but-unavailable answer) rather than
  /// reaching for a call that will abort.
  private static func requireFaceTimeHost() throws {
    guard Bundle.main.bundleIdentifier == faceTimeBundleID else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "FaceTime",
        requires: "the helper to be running inside FaceTime.app; this host is "
          + (Bundle.main.bundleIdentifier ?? "unknown")
      )
    }
  }

  /// Stands up the long-lived client if it is not already up.
  ///
  /// Idempotent and cheap after the first call. The registration and initial-state fetch are
  /// awaited so the first operation does not race an unpopulated client — the precise race
  /// that makes the old helper return empty lists.
  @discardableResult
  static func ensureClient() async throws -> AnyObject {
    try requireFaceTimeHost()
    if let client = conversationClient, clientReady { return client }

    let client: AnyObject
    if let existing = conversationClient {
      client = existing
    } else {
      guard let type = IMCoreRuntime.lookUpClass("TUConversationManagerXPCClient") else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "FaceTime",
          requires: "TUConversationManagerXPCClient — is the helper in FaceTime.app?"
        )
      }
      guard let instance = try? IMCoreRuntime.send(type as AnyObject, "alloc"),
        let initialized = try? IMCoreRuntime.send(instance, "init")
      else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "could not construct the FaceTime conversation client"
        )
      }
      conversationClient = initialized
      client = initialized
      // NO delegate installed. `TUConversationManagerDataSourceDelegate` is a large
      // protocol, and `TUConversationManagerXPCClient` calls its methods WITHOUT
      // `respondsToSelector:` guards — `handleServerDisconnect` invokes one on the
      // delegate, and an incomplete shim there is `doesNotRecognizeSelector:` →
      // `abort()`, which crashes FaceTime.app. Measured. The link, dial, answer and
      // admit paths do not need the delegate, and Flow C's "wait for join" is done by
      // POLLING `faceTimeMembers` on the server, so the push event is not required to
      // ship. A delegate can be added later only if EVERY protocol method is
      // implemented — see FaceTimeDelegateShim.
      observeReconnect()
    }

    // Register, then fetch initial state. Both are completion-based; both are awaited so
    // the client is actually usable when this returns.
    await callAwaitingCompletion(client, "registerWithCompletionHandler:")
    await callAwaitingCompletion(client, "fetchInitialStateWithCompletionHandler:")
    clientReady = true
    return client
  }

  /// Installs the delegate that turns membership changes into events.
  ///
  /// The delegate is where "someone joined / is knocking" arrives without a swizzle — the
  /// clean path the old helper never wired (its pending-member swizzle is commented out).
  private static func installDelegate(on client: AnyObject) {
    let shim = FaceTimeDelegateShim { conversationUUID, members in
      FaceTimeBridge.emit?(
        "ft-members-changed",
        [
          "conversationUUID": conversationUUID,
          "members": members,
        ])
    }
    delegateShim = shim
    // `setDelegate:` via the runtime, guarded — a delegate that fails to attach loses
    // events but must not crash the host.
    _ = try? IMCoreRuntime.invoke(client, "setDelegate:", [shim])
  }

  /// Re-registers when the daemon posts its "clients should connect" notification.
  ///
  /// `CSDConversationManagerClientsShouldConnectNotification` is the daemon telling clients
  /// to (re)establish. Observing it is how a long-lived client survives the daemon cycling
  /// without going silently stale — the failure mode a throwaway client never even reaches,
  /// because it is destroyed inside a single request.
  private static func observeReconnect() {
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("CSDConversationManagerClientsShouldConnectNotification"),
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        clientReady = false
        Task { _ = try? await ensureClient() }
      }
    }
  }

  // MARK: - Links (Flow A, and link-for-call in B/C)

  /// Mints a link for a NEW conversation — no call placed. Flow A.
  ///
  /// `invitedAddresses` pre-invites those people onto the link. Whether that RINGS them or
  /// only adds a passive invitation is the thing under test — either way the Mac never joins
  /// a call, so there is nothing to leave.
  static func generateLink(invitedAddresses: [String] = []) async throws -> FaceTimeLink {
    let client = try await ensureClient()
    let handles = invitedAddresses.compactMap(makeHandle)
    return try await generateLink(on: client, forConversation: nil, invitedHandles: handles)
  }

  /// Mints a link for an EXISTING call the Mac is in. Flow B/C.
  ///
  /// The conversation is POLLED rather than read once. A freshly-dialled call has no active
  /// conversation at the instant `dialWithRequest:` returns — the call has to establish
  /// first — so reading immediately yields nil and the link generation fails with no
  /// explanation. Measured: a dial that rang and connected still produced "FaceTime
  /// returned no link" because this ran too early.
  static func generateLink(forCall callUUID: String) async throws -> FaceTimeLink {
    let client = try await ensureClient()
    let center = try callCenter()

    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    var conversation: AnyObject?
    var sawCall = false

    while ContinuousClock.now < deadline {
      if let call = try? IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) {
        sawCall = true
        if let active = try? IMCoreRuntime.send(center, "activeConversationForCall:", call) {
          conversation = active
          break
        }
      }
      try? await Task.sleep(for: .milliseconds(500))
    }

    guard let conversation else {
      // Distinguish the two failures: a call we never found (wrong UUID, or it ended)
      // versus one that exists but never grew a conversation.
      throw PrivateAPIError.rejectedByMessages(
        reason: sawCall
          ? "call \(callUUID) never became an active conversation within 15s"
          : "no FaceTime call with UUID \(callUUID)"
      )
    }
    return try await generateLink(on: client, forConversation: conversation)
  }

  /// The shared link-minting path. `conversation` nil means "a fresh link with no call."
  private static func generateLink(
    on client: AnyObject,
    forConversation conversation: AnyObject?,
    invitedHandles: [AnyObject] = []
  ) async throws -> FaceTimeLink {
    let box = ResultBox()

    // The completion is `(TUConversationLink *, NSError *)` — TWO arguments. A one-arg
    // block would silently drop the error, leaving "returned no link" with no cause; the
    // two-arg path captures both so a daemon-side failure is reported.
    if let conversation {
      await callAwaitingCompletion2(
        client, "generateLinkForConversation:completionHandler:",
        leading: [conversation]
      ) { result, error in
        box.value = result
        box.error = error
      }
    } else {
      // `linkLifetimeScope: 0` is the default the ObjC helper uses; an empty invited set
      // means "a link anyone with the URL can use." Non-empty pre-invites those handles.
      await callAwaitingCompletion2(
        client, "generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:",
        leading: [invitedHandles, NSNumber(value: 0)]
      ) { result, error in
        box.value = result
        box.error = error
      }
    }

    guard let link = box.value else {
      let detail = (box.error as? NSError).map { ": \($0.localizedDescription)" } ?? ""
      throw PrivateAPIError.rejectedByMessages(reason: "FaceTime returned no link\(detail)")
    }
    return try decodeLink(link)
  }

  /// Reads a `TUConversationLink` into the contract's shape.
  private static func decodeLink(_ link: AnyObject) throws -> FaceTimeLink {
    guard let url = try? IMCoreRuntime.send(link, "URL"),
      let string = ((try? IMCoreRuntime.string(url, "absoluteString")) ?? nil),
      !string.isEmpty
    else {
      throw PrivateAPIError.rejectedByMessages(reason: "the FaceTime link has no URL")
    }
    let groupUUID = (try? IMCoreRuntime.send(link, "groupUUID"))
      .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil }
    let expiration = (try? IMCoreRuntime.send(link, "expirationDate")) as? Date
    return FaceTimeLink(
      url: string,
      groupUUID: groupUUID,
      name: (try? IMCoreRuntime.string(link, "linkName")) ?? nil,
      expiresAt: expiration
    )
  }

  // MARK: - Outbound call (Flow B)

  /// Places an outgoing FaceTime call so the target's device rings.
  static func dial(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    try requireFaceTimeHost()
    let center = try callCenter()
    guard let dialType = IMCoreRuntime.lookUpClass("TUDialRequest") else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "dialFaceTime", requires: "TUDialRequest"
      )
    }
    // `-[TUDialRequest init]` is REFUSED: TelephonyUtilities asserts
    // "Don't call -[TUDialRequest init], call designated initializer instead." (measured).
    //
    // The right designated initializer is `initWithProvider:` — NOT `initWithService:`
    // with a guessed integer. A guessed service produced a request with no provider, and
    // TelephonyUtilities' own `validityErrors` named it exactly:
    //   Code=6 "Requested video for a provider which doesn't support it"
    //   Code=8 "Provider does not support the specified handle type"
    // Both are provider complaints. `TUCallProviderManager.faceTimeProvider` is the real
    // FaceTime provider, and asking for it removes the guesswork entirely.
    guard let dial = try? IMCoreRuntime.send(dialType as AnyObject, "alloc") else {
      throw PrivateAPIError.rejectedByMessages(reason: "could not allocate a dial request")
    }

    // `TUCallProviderManager` has no singleton, but the call center already holds one —
    // and it is the SAME manager FaceTime.app itself dials through, so its providers are
    // the real, registered ones rather than a detached copy.
    guard let manager = try? IMCoreRuntime.send(center, "providerManager") else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "TUCallCenter has no providerManager"
      )
    }
    guard let provider = try? IMCoreRuntime.send(manager, "faceTimeProvider") else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "no FaceTime provider — the account may not be signed in to FaceTime"
      )
    }

    guard let request0 = IMCoreRuntime.initWithObject(dial, "initWithProvider:", provider) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "TUDialRequest rejected initWithProvider:"
      )
    }

    // Handles are set AFTER `initWithProvider:` — the initializer builds a fresh request,
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

    // Diagnostics for the failure path. `validityErrors` is TelephonyUtilities' own
    // verdict on the request and names the exact refusal — far better than the opaque
    // `TUDialRequestErrorDomain` code the dial returns.
    //
    // NOTE: `-[TUHandle description]` REDACTS the address (it prints an opaque `u:…`
    // token), so a logged handle looking mangled is a privacy feature, not a bug — the
    // `value` property holds the real address. Measured; do not "fix" the constructors
    // based on the description alone.
    let validity =
      (try? IMCoreRuntime.send(request0, "validityErrors"))
      .map { String(describing: $0) } ?? "none"
    let requestDescription = (try? IMCoreRuntime.string(request0, "description")) ?? nil

    let box = ResultBox()
    await callAwaitingCompletion2(
      center, "dialWithRequest:completionWithError:", leading: [request0]
    ) { result, error in
      box.value = result
      box.error = error
    }

    // The call is discoverable on the center whether or not the completion handed one back.
    let call =
      box.value
      ?? (try? IMCoreRuntime.send(center, "currentCalls")).flatMap { ($0 as? [AnyObject])?.last }
    guard let call else {
      let why = (box.error as? NSError).map { "; \($0.localizedDescription)" } ?? ""
      throw PrivateAPIError.rejectedByMessages(
        reason: "the dial produced no call\(why). validityErrors=\(validity) "
          + "request=\(requestDescription ?? "nil")"
      )
    }
    // Silence the Mac immediately — it is only holding the call open for the hand-off.
    silenceLocalParticipant(call)
    return decodeCall(call)
  }

  /// Mutes the Mac's microphone and stops its camera on a call it is only HOLDING OPEN.
  ///
  /// During a hand-off the Mac is a genuine participant: until the client joins and the Mac
  /// drops out, the other party sees the Mac's camera and hears its microphone. That window
  /// is short but it is a live audio/video feed from an unattended computer — usually in
  /// someone's home — so it is closed immediately rather than tolerated.
  ///
  /// Note this does NOT make the call audio-only: it is still a video call, and the client
  /// that joins sends its own camera normally. Only the Mac's uplink is silenced.
  ///
  /// Best-effort: failing to mute costs privacy, not correctness, so it never fails the
  /// call. `setMuted:` returns a BOOL that is ignored — `callBool` casts to a void-returning
  /// signature, which is safe here because the result simply stays in the return register.
  static func silenceLocalParticipant(_ call: AnyObject) {
    try? IMCoreRuntime.callBool(call, "setMuted:", true)
    try? IMCoreRuntime.callBool(call, "setIsSendingVideo:", false)
  }

  /// Mutes a call by UUID and REPORTS the resulting state.
  ///
  /// Applying mute at dial time does not stick: the call is still `outgoing` (ringing) and
  /// the media session does not exist yet, so the setters are applied to a call that has no
  /// uplink to mute and are lost when it connects. MEASURED — the Mac's camera and
  /// microphone were live for the callee despite muting at dial.
  ///
  /// So this is re-assertable and idempotent: the hand-off watcher calls it on every poll
  /// until the Mac leaves, which covers the moment the call actually connects. It returns
  /// what the call reports afterwards so a caller can see whether it took.
  static func silence(callUUID: String) async throws -> (muted: Bool, sendingVideo: Bool) {
    try requireFaceTimeHost()
    let center = try callCenter()
    guard let call = try? IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
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
    guard let call = try? IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
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
    guard let call = try? IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
      // Already gone is success: the goal is "the Mac is not in this call."
      return
    }
    try IMCoreRuntime.invoke(center, "disconnectCall:", [call])
  }

  // MARK: - Members

  static func admit(conversationUUID: String, handle: String) async throws {
    let client = try await ensureClient()
    // The member object may live in the active conversation OR in the incoming-pending
    // map; the conversation passed to `approvePendingMember:forConversation:` must be the
    // one the member came from.
    let candidates = [
      conversation(withGroupUUID: conversationUUID, on: client),
      incomingPendingConversation(withGroupUUID: conversationUUID, on: client),
    ].compactMap { $0 }

    for conversation in candidates {
      guard let member = anyMember(handle: handle, in: conversation) else { continue }
      try IMCoreRuntime.invoke(
        client, "approvePendingMember:forConversation:", [member, conversation]
      )
      return
    }
    throw PrivateAPIError.rejectedByMessages(
      reason: "\(handle) is not waiting in \(conversationUUID)"
    )
  }

  /// Finds a member by handle across BOTH `pendingMembers` and `remoteMembers` — a
  /// link-joiner awaiting admission shows up in the latter.
  private static func anyMember(handle: String, in conversation: AnyObject) -> AnyObject? {
    roster(of: conversation).first { member in
      memberHandleValue(member.object)?.caseInsensitiveCompare(handle) == .orderedSame
    }?.object
  }

  /// Every member associated with a conversation, tagged with which collection it came from.
  ///
  /// `lightweightMembers` is where a browser joining by LINK lives — it is NOT a subset of
  /// `remoteMembers`, and admitting one means finding it here.
  private static func roster(of conversation: AnyObject) -> [(
    object: AnyObject, declaredPending: Bool
  )] {
    func read(_ selector: String) -> [AnyObject] {
      (try? IMCoreRuntime.send(conversation, selector)).map(collection) ?? []
    }
    return read("pendingMembers").map { ($0, true) }
      + read("remoteMembers").map { ($0, false) }
      + read("lightweightMembers").map { ($0, false) }
  }

  /// Handles of the people ACTUALLY CONNECTED right now, or nil if this OS exposes neither
  /// active-participant set.
  ///
  /// This is the distinction the hand-off turns on, and missing it is what killed three live
  /// calls. `remoteMembers`/`lightweightMembers` are the conversation's ROSTER — a browser
  /// lands there the instant it opens the link, while still showing "Waiting to be let in…".
  /// `activeRemoteParticipants`/`activeLightweightParticipants` are who is really in. Reading
  /// roster membership as "joined" made the Mac hand off to somebody who had never been
  /// admitted, and the call died the moment the Mac left.
  ///
  /// Returns nil — rather than an empty set — when neither selector resolves, so the caller
  /// can tell "nobody is connected" from "this OS won't say", and fall back instead of
  /// declaring the whole call empty.
  private static func activeParticipantHandles(of conversation: AnyObject) -> Set<String>? {
    var resolved = false
    var values: Set<String> = []
    for selector in ["activeRemoteParticipants", "activeLightweightParticipants"] {
      guard let raw = try? IMCoreRuntime.send(conversation, selector) else { continue }
      resolved = true
      for participant in collection(raw) {
        // An element is a TUHandle, a TUConversationMember, or a participant wrapping
        // one — take whichever spelling answers.
        let direct = ((try? IMCoreRuntime.string(participant, "value")) ?? nil)
        let nested = (try? IMCoreRuntime.send(participant, "handle"))
          .flatMap { ((try? IMCoreRuntime.string($0, "value")) ?? nil) }
        if let value = (direct ?? nested), !value.isEmpty {
          values.insert(value.lowercased())
        }
      }
    }
    return resolved ? values : nil
  }

  static func members(conversationUUID: String) async throws -> [FaceTimeMember] {
    let client = try await ensureClient()
    var decoded: [FaceTimeMember] = []

    if let conversation = conversation(withGroupUUID: conversationUUID, on: client) {
      decoded += decodeMembers(of: conversation)
    }
    // The LOBBY lives here, not in `conversation.pendingMembers`. The daemon calls
    // `updateIncomingPendingConversationsByGroupUUID:` on the client directly, so this is
    // populated even though no delegate is installed.
    if let waiting = incomingPendingConversation(withGroupUUID: conversationUUID, on: client) {
      decoded += decodeMembers(of: waiting, forcePending: true)
    }

    // De-duplicate by handle. A member can appear in several collections at once; the
    // active-participant sets are the authority, so an "in the call" reading wins over a
    // roster entry that merely lists them.
    var byHandle: [String: FaceTimeMember] = [:]
    for member in decoded {
      let key = member.handle.value.lowercased()
      if let existing = byHandle[key], existing.isActive, !member.isActive { continue }
      byHandle[key] = member
    }
    return Array(byHandle.values)
  }

  /// The conversation as it appears in the daemon's INCOMING PENDING map — i.e. people
  /// knocking on this link who have not been let in.
  private static func incomingPendingConversation(
    withGroupUUID uuid: String,
    on client: AnyObject
  ) -> AnyObject? {
    guard
      let map = (try? IMCoreRuntime.send(client, "incomingPendingConversationsByGroupUUID"))
        as? [AnyHashable: AnyObject]
    else { return nil }
    for (key, conversation) in map {
      let keyString =
        (key as? NSUUID)?.uuidString
        ?? ((try? IMCoreRuntime.send(conversation, "groupUUID"))
          .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil })
      if keyString?.caseInsensitiveCompare(uuid) == .orderedSame { return conversation }
    }
    return nil
  }

  /// Raw TelephonyUtilities state for one conversation, as strings.
  ///
  /// Exists because the lobby state could not be located by reading the properties the
  /// headers suggest: a link-joiner stuck at "Waiting to be let in…" reported
  /// `joinedFromLetMeIn = true` and appeared in `remoteMembers`, so every derived flag read
  /// "already in". Rather than guess again, this dumps what the objects actually say and the
  /// answer gets read off a live call.
  static func debugState(conversationUUID: String) async throws -> [String: String] {
    let client = try await ensureClient()
    var out: [String: String] = [:]

    let byGroup = (try? IMCoreRuntime.send(client, "conversationsByGroupUUID"))
    out["conversationsByGroupUUID"] = byGroup.map { String(describing: $0) } ?? "nil"
    let pendingMap = (try? IMCoreRuntime.send(client, "incomingPendingConversationsByGroupUUID"))
    out["incomingPendingConversationsByGroupUUID"] =
      pendingMap.map { String(describing: $0) } ?? "nil"

    // Link sources, so a link that cannot be invalidated can be explained rather than
    // reported as "nothing to do".
    out["activatedConversationLinks"] =
      (try? IMCoreRuntime.send(client, "activatedConversationLinks"))
      .map { String(describing: $0) } ?? "nil"
    let activeLinks = ResultBox()
    await callAwaitingCompletion(
      client, "getActiveLinksWithCreatedOnly:completionHandler:",
      leading: [NSNumber(value: false)]
    ) { result in activeLinks.value = result }
    out["getActiveLinks(createdOnly:false)"] =
      activeLinks.value.map { String(describing: $0) } ?? "nil"

    if let conversation = conversation(withGroupUUID: conversationUUID, on: client) {
      out["conversation"] = String(describing: conversation)
      // The active-participant sets are the ones the hand-off decision rests on. If a
      // selector does not resolve here, `activeParticipantHandles` returns nil and
      // presence silently falls back to roster membership — the original bug. Dumped
      // so that is verifiable rather than assumed.
      for (label, selector) in [
        ("pendingMembers", "pendingMembers"),
        ("remoteMembers", "remoteMembers"),
        ("lightweightMembers", "lightweightMembers"),
        ("activeRemoteParticipants", "activeRemoteParticipants"),
        (
          "activeLightweightParticipants",
          "activeLightweightParticipants"
        ),
        ("localMember", "localMember"),
      ] {
        let value = (try? IMCoreRuntime.send(conversation, selector))
        out[label] = value.map { String(describing: $0) } ?? "nil"
      }
    } else {
      out["conversation"] = "NOT FOUND for \(conversationUUID)"
    }
    return out
  }

  /// Where a call is now, or `.disconnected` when TelephonyUtilities no longer has it.
  ///
  /// A call that has ENDED is simply absent from the call centre — there is no tombstone —
  /// so "not found" and "disconnected" are the same answer, and reporting it as
  /// `.disconnected` lets a caller stop watching rather than poll a call that will never
  /// change again.
  static func callStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    _ = try await ensureClient()
    let center = try callCenter()
    guard let call = try? IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) else {
      return .disconnected
    }
    return FaceTimeCallStatus(raw: (try? IMCoreRuntime.integer(call, "callStatus")) ?? 0)
  }

  /// Every call the Mac is currently in.
  ///
  /// `currentCalls` is TelephonyUtilities' own list, so it sees calls this server knows
  /// nothing about — which is the point: after a server restart the Mac can still be sitting
  /// in a call whose hand-off watcher died with the old process.
  static func activeCalls() async throws -> [FaceTimeCall] {
    _ = try await ensureClient()
    let center = try callCenter()
    let calls = collection(try? IMCoreRuntime.send(center, "currentCalls"))
    return calls.map(decodeCall).filter { !$0.callUUID.isEmpty }
  }

  // MARK: - Blocking alerts

  /// What FaceTime.app is showing, for diagnosing a wedged dial.
  ///
  /// Dialling an address that is not FaceTime-capable does not fail the API call — a
  /// `TUCall` is created and reports `outgoing` — but FaceTime puts up "…is not available
  /// for FaceTime" and the call never forms a conversation. The alert is a UI object the
  /// private API says nothing about, so it is inspected through AppKit.
  @MainActor
  static func windowSummaries() -> [String] {
    NSApplication.shared.windows.map { window in
      let sheet = window.attachedSheet.map { " attachedSheet=\(type(of: $0))" } ?? ""
      return "\(type(of: window)) title=\(window.title.isEmpty ? "-" : window.title) "
        + "visible=\(window.isVisible) sheet=\(window.isSheet) "
        + "level=\(window.level.rawValue)\(sheet)"
    }
  }

  /// Dismisses a blocking alert, CANCELLING rather than confirming.
  ///
  /// Deliberately the safe button: this alert's other options offer to call a DIFFERENT
  /// address on the contact card, and dismissing it by confirming could place a call to
  /// someone the client never asked for. Cancelling only ever un-wedges the app.
  ///
  /// Returns how many were dismissed, so a caller can tell "cleared a blockage" from
  /// "nothing was blocking".
  @MainActor
  static func dismissBlockingAlerts() -> Int {
    var dismissed = 0
    let app = NSApplication.shared

    // App-modal alert: end the modal session, then close the window it ran.
    if let modal = app.modalWindow {
      app.abortModal()
      modal.close()
      dismissed += 1
    }
    // Sheet on any window: end it with a cancel response.
    for window in app.windows {
      guard let sheet = window.attachedSheet else { continue }
      window.endSheet(sheet, returnCode: .cancel)
      dismissed += 1
    }
    return dismissed
  }

  // MARK: - Invalidating links

  /// Invalidates active links, and returns the URLs it invalidated.
  ///
  /// `urls` nil means "all created links" — the cleanup path. Otherwise only links whose URL
  /// matches are invalidated. Reads the live list via `getActiveLinksWithCreatedOnly:` (the
  /// XPC round trip that actually reflects the daemon's state) rather than the possibly-stale
  /// `activatedConversationLinks` property.
  /// How many links the last `invalidateLinks` could see. Diagnostic only: "invalidated
  /// nothing" means something different when the snapshot was empty than when it was full.
  private(set) nonisolated(unsafe) static var lastLinkSnapshotCount = 0

  static func invalidateLinks(matching urls: [String]?) async throws -> [String] {
    let client = try await ensureClient()

    // Gather links from every source and de-duplicate by URL — no single accessor is
    // reliable without the data-source delegate, so union them: the XPC list (all links,
    // not just created-this-session) and the client's own `activatedConversationLinks`.
    var links: [AnyObject] = []

    let box = ResultBox()
    await callAwaitingCompletion(
      client, "getActiveLinksWithCreatedOnly:completionHandler:",
      leading: [NSNumber(value: false)]
    ) { result in box.value = result }
    links += collection(box.value)
    // Union with the client's own list too. MEASURED, macOS 26.5.2: without the
    // data-source delegate installed, `getActiveLinksWithCreatedOnly:` comes back EMPTY
    // (the client's link state is populated through the delegate, which is not attached
    // — see ensureClient), while `activatedConversationLinks` holds the real
    // TUConversationLink objects, if stale. So the property is the ONLY reliable source of
    // link objects to invalidate here; the XPC call is kept in the union for the day a
    // safe delegate makes it authoritative.
    links += collection(try? IMCoreRuntime.send(client, "activatedConversationLinks"))

    lastLinkSnapshotCount = links.count
    var invalidated: [String] = []
    var seen = Set<String>()
    var lastError: String?
    var matched = 0
    for link in links {
      guard
        let url =
          ((try? IMCoreRuntime.send(link, "URL")).flatMap {
            (try? IMCoreRuntime.string($0, "absoluteString")) ?? nil
          }), seen.insert(url).inserted
      else { continue }
      if let urls, !urls.contains(url) { continue }
      matched += 1

      // The completion is `(BOOL success, NSError *error)` — arg0 is a BOOL, not an
      // object, so it needs a bool-first block. Only count a link as invalidated when
      // the daemon reports success; otherwise carry the reason so the failure is visible
      // rather than a false "done".
      let box = ResultBox()
      await callAwaitingCompletionBool(
        client, "invalidateLink:deleteReason:completionHandler:",
        leading: [link, NSNumber(value: 1)]
      ) { success, error in
        box.success = success
        box.error = error
      }

      if box.success {
        invalidated.append(url)
      } else if let error = box.error as? NSError {
        lastError = error.localizedDescription
      } else {
        // The daemon reported neither success nor an error. Without the data-source
        // delegate, `activatedConversationLinks` can hold link objects the daemon no
        // longer recognises, and invalidating one of those completes with a bare
        // `false`. Named explicitly: reporting an empty success here is what made a
        // failed cleanup look like "there was nothing to clean up".
        lastError =
          "the daemon declined without an error — the link object is "
          + "probably stale (activatedConversationLinks is not refreshed without "
          + "the data-source delegate)"
      }
    }
    // If links were found but NONE could be invalidated, say so. An empty list here used
    // to be indistinguishable from "no links exist", so orphaned links looked cleaned up.
    if invalidated.isEmpty, matched > 0 {
      throw PrivateAPIError.rejectedByMessages(
        reason: "could not invalidate \(matched) of \(links.count) known link(s): "
          + (lastError ?? "no reason reported")
      )
    }
    if invalidated.isEmpty, matched == 0, !links.isEmpty {
      throw PrivateAPIError.rejectedByMessages(
        reason: "none of the requested links are among the \(links.count) FaceTime "
          + "knows about"
      )
    }
    return invalidated
  }

  // MARK: - Reading conversations/members

  /// The active conversations keyed by group UUID.
  ///
  /// Read from `conversationsByGroupUUID` on the XPC client — NOT `activeConversations`,
  /// which is a `TUConversationManager` accessor and is absent on the XPC client (verified
  /// against the runtime; the ObjC helper's ktool header put it on the wrong class). The
  /// dictionary is only populated once the client has fetched initial state, which is the
  /// whole reason `ensureClient()` awaits that before any read.
  private static func conversationsByGroupUUID(on client: AnyObject) -> [AnyHashable: AnyObject] {
    ((try? IMCoreRuntime.send(client, "conversationsByGroupUUID")) as? [AnyHashable: AnyObject])
      ?? [:]
  }

  private static func conversation(withGroupUUID uuid: String, on client: AnyObject) -> AnyObject? {
    let byGroup = conversationsByGroupUUID(on: client)
    // The keys are NSUUIDs; match case-insensitively on the string form so a caller can
    // pass either casing.
    for (key, conversation) in byGroup {
      let keyString =
        (key as? NSUUID)?.uuidString
        ?? ((try? IMCoreRuntime.send(conversation, "groupUUID"))
          .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil })
      if keyString?.caseInsensitiveCompare(uuid) == .orderedSame { return conversation }
    }
    return nil
  }

  private static func pendingMember(handle: String, in conversation: AnyObject) -> AnyObject? {
    let pending = (try? IMCoreRuntime.send(conversation, "pendingMembers")).map(collection) ?? []
    return pending.first { member in
      memberHandleValue(member)?.caseInsensitiveCompare(handle) == .orderedSame
    }
  }

  private static func decodeMembers(
    of conversation: AnyObject,
    forcePending: Bool = false
  ) -> [FaceTimeMember] {
    // Nil means the OS did not answer, so presence can't be judged — fall back to the
    // roster's own claim rather than reporting everyone as stuck in the lobby.
    let active = activeParticipantHandles(of: conversation)

    return roster(of: conversation).compactMap { entry in
      guard let value = memberHandleValue(entry.object) else { return nil }
      let joined = active.map { $0.contains(value.lowercased()) } ?? !entry.declaredPending
      let knocked = ((try? IMCoreRuntime.send(entry.object, "dateReceivedLetMeIn")) ?? nil) != nil
      return FaceTimeMember(
        handle: FaceTimeHandle(value: value),
        nickname: ((try? IMCoreRuntime.string(entry.object, "nickname")) ?? nil),
        isPending: forcePending || !joined,
        isWaitingToBeLetIn: (forcePending || !joined) && (knocked || entry.declaredPending),
        joinedFromLetMeIn: (try? IMCoreRuntime.bool(entry.object, "joinedFromLetMeIn")) ?? false,
        isActive: joined && !forcePending,
        isLightweight: (try? IMCoreRuntime.bool(entry.object, "isLightweightMember")) ?? false
      )
    }
  }

  private static func memberHandleValue(_ member: AnyObject) -> String? {
    guard let handle = try? IMCoreRuntime.send(member, "handle") else { return nil }
    return ((try? IMCoreRuntime.string(handle, "value")) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
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

  // MARK: - Plumbing

  private static func callCenter() throws -> AnyObject {
    guard let center = try? IMCoreRuntime.sharedInstance(ofClass: "TUCallCenter") else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "FaceTime",
        requires: "TUCallCenter — is the helper in FaceTime.app?"
      )
    }
    return center
  }

  /// `+[TUHandle handleWithValue:]`-style construction from an address. TelephonyUtilities
  /// exposes several normalized constructors; `handleWithDestinationID:` takes a raw
  /// address, which is what a client sends.
  /// Builds a `TUHandle` from a plain address, using the NORMALIZED constructors.
  ///
  /// NOT `handleWithDestinationID:`. MEASURED on macOS 26.5.2: that one mangles the address
  /// into an opaque token — `person@example.com` became
  /// `<TUHandle type=EmailAddress, value=u:Ml4lbkVH2eOd+pR0, normalizedValue=(null)>` — and
  /// the call center then refuses the dial with `TUDialRequestErrorDomain error 11`. It
  /// expects a destination URI, not a bare address.
  ///
  /// The normalized constructors keep the real value and populate `normalizedValue`, which
  /// is what the dial path matches on. Email and phone have separate ones, so the address is
  /// classified first; phone numbers need a country code for normalization.
  private static func makeHandle(_ address: String) -> AnyObject? {
    guard let type = IMCoreRuntime.lookUpClass("TUHandle") else { return nil }
    let handleClass = type as AnyObject

    if address.contains("@") {
      if let handle = try? IMCoreRuntime.send(
        handleClass, "normalizedEmailAddressHandleForValue:", address
      ) {
        return handle
      }
    } else {
      // The current region's code, so `+1…` and a local-format number both normalize.
      let region = Locale.current.region?.identifier ?? "US"
      if let handle = try? IMCoreRuntime.send(
        handleClass, "normalizedPhoneNumberHandleForValue:isoCountryCode:", address, region
      ) {
        return handle
      }
    }

    // Generic normalization, then the destination-URI form, as fallbacks — better a
    // rejected dial than no handle at all.
    if let handle = try? IMCoreRuntime.send(
      handleClass, "normalizedGenericHandleForValue:", address
    ) {
      return handle
    }
    return try? IMCoreRuntime.send(handleClass, "normalizedHandleWithDestinationID:", address)
  }

  private static func collection(_ value: AnyObject?) -> [AnyObject] {
    guard let value else { return [] }
    if let array = value as? [AnyObject] { return array }
    if let set = value as? NSSet { return set.allObjects as [AnyObject] }
    return []
  }

  /// Runs a completion-based selector and waits for it, bounded.
  ///
  /// `leading` are the arguments before the completion block. The block is appended and its
  /// single object argument (if any) handed to `onResult`. A timeout resolves the wait so a
  /// daemon that never answers does not hold the helper's request slot forever.
  private static func callAwaitingCompletion(
    _ target: AnyObject,
    _ selector: String,
    leading: [Any] = [],
    timeout: Duration = .seconds(20),
    onResult: (@Sendable (AnyObject?) -> Void)? = nil
  ) async {
    let sentinel = CompletionSentinel()
    let block: @convention(block) (AnyObject?) -> Void = { value in
      onResult?(value)
      sentinel.finish()
    }
    do {
      try IMCoreRuntime.invoke(
        target, selector, leading + [unsafeBitCast(block, to: AnyObject.self)]
      )
    } catch {
      sentinel.finish()
    }

    let watchdog = Task.detached {
      try? await Task.sleep(for: timeout)
      sentinel.finish()
    }
    await sentinel.wait()
    watchdog.cancel()
  }

  /// A two-argument completion — `(result, error)`, the FaceTime link shape. Kept separate
  /// from the one-argument path because declaring MORE block parameters than the callee
  /// passes reads uninitialised registers as objects, so a two-arg block is only safe for a
  /// completion that genuinely passes two arguments.
  private static func callAwaitingCompletion2(
    _ target: AnyObject,
    _ selector: String,
    leading: [Any] = [],
    timeout: Duration = .seconds(20),
    onResult: @escaping @Sendable (AnyObject?, AnyObject?) -> Void
  ) async {
    let sentinel = CompletionSentinel()
    let block: @convention(block) (AnyObject?, AnyObject?) -> Void = { result, error in
      onResult(result, error)
      sentinel.finish()
    }
    do {
      try IMCoreRuntime.invoke(
        target, selector, leading + [unsafeBitCast(block, to: AnyObject.self)]
      )
    } catch {
      // Surface the invoke failure THROUGH the completion's error argument, so the
      // caller's error handling is one path rather than two.
      onResult(
        nil,
        NSError(
          domain: "BBFaceTime", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "call failed: \(error)"]
        ))
      sentinel.finish()
    }

    let watchdog = Task.detached {
      try? await Task.sleep(for: timeout)
      sentinel.finish()
    }
    await sentinel.wait()
    watchdog.cancel()
  }

  /// A completion whose FIRST argument is a `BOOL` — `(success, error)`. `invalidateLink:`
  /// has this shape, and a `BOOL` is not an object, so it needs a block declared with a
  /// leading `Bool` rather than the object-first blocks above; reading a BOOL byte as an
  /// object pointer would misinterpret it.
  private static func callAwaitingCompletionBool(
    _ target: AnyObject,
    _ selector: String,
    leading: [Any] = [],
    timeout: Duration = .seconds(20),
    onResult: @escaping @Sendable (Bool, AnyObject?) -> Void
  ) async {
    let sentinel = CompletionSentinel()
    let block: @convention(block) (Bool, AnyObject?) -> Void = { success, error in
      onResult(success, error)
      sentinel.finish()
    }
    do {
      try IMCoreRuntime.invoke(
        target, selector, leading + [unsafeBitCast(block, to: AnyObject.self)]
      )
    } catch {
      onResult(
        false,
        NSError(
          domain: "BBFaceTime", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "call failed: \(error)"]
        ))
      sentinel.finish()
    }

    let watchdog = Task.detached {
      try? await Task.sleep(for: timeout)
      sentinel.finish()
    }
    await sentinel.wait()
    watchdog.cancel()
  }
}

// MARK: - Small helpers

/// A mutable box for a completion's result, captured across the async boundary.
private final class ResultBox: @unchecked Sendable {
  var value: AnyObject?
  var error: AnyObject?
  var success = false
}

/// One-shot resume, safe from any thread — completions arrive on the daemon's queue.
private final class CompletionSentinel: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var finished = false

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if finished {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()
    }
  }

  func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume()
  }
}

/// The object set as the conversation client's delegate.
///
/// It implements the `TUConversationManagerDataSourceDelegate` selectors the port cares about
/// — membership and pending-member changes — and forwards them as a simplified event. The
/// protocol type is not available to link against, so the methods are matched by selector and
/// the object is attached with `setDelegate:`; `respondsToSelector:` on the real protocol is
/// satisfied because these are concrete `@objc` methods.
private final class FaceTimeDelegateShim: NSObject {
  private let onMembership: (String, [[String: Any]]) -> Void

  init(onMembership: @escaping (String, [[String: Any]]) -> Void) {
    self.onMembership = onMembership
  }

  /// `conversationsChanged...conversationsByGroupUUID:oldConversationsByGroupUUID:` — a
  /// membership change. The diff old→new is what tells "the client joined" from "still just
  /// the caller"; here the whole new set is forwarded and the diff is computed server-side.
  @objc(conversationsChangedForDataSource:conversationsByGroupUUID:oldConversationsByGroupUUID:)
  func conversationsChanged(
    _ dataSource: Any, conversationsByGroupUUID: Any, oldConversationsByGroupUUID: Any
  ) {
    forward(conversationsByGroupUUID)
  }

  /// `...updatedIncomingPendingConversationsByGroupUUID:` — someone is knocking.
  @objc(conversationsChangedForDataSource:updatedIncomingPendingConversationsByGroupUUID:)
  func pendingConversationsChanged(_ dataSource: Any, updatedIncoming: Any) {
    forward(updatedIncoming)
  }

  private func forward(_ conversationsByGroupUUID: Any) {
    guard let map = conversationsByGroupUUID as? [AnyHashable: AnyObject] else { return }
    for (key, conversation) in map {
      let uuid =
        (key as? NSUUID)?.uuidString
        ?? ((try? IMCoreRuntime.string(conversation, "groupUUID")) ?? nil)
        ?? String(describing: key)
      let members = FaceTimeBridge.membersPayload(of: conversation)
      onMembership(uuid, members)
    }
  }
}

extension FaceTimeBridge {
  /// Member payloads for the event, built off a conversation object. `nonisolated` so the
  /// delegate shim can call it from the daemon's queue; every access is a guarded read.
  nonisolated static func membersPayload(of conversation: AnyObject) -> [[String: Any]] {
    func decode(_ value: AnyObject?, pending: Bool) -> [[String: Any]] {
      let set: [AnyObject]
      if let array = value as? [AnyObject] {
        set = array
      } else if let ns = value as? NSSet {
        set = ns.allObjects as [AnyObject]
      } else {
        set = []
      }
      return set.compactMap { member in
        guard let handle = try? IMCoreRuntime.send(member, "handle"),
          let value = ((try? IMCoreRuntime.string(handle, "value")) ?? nil),
          !value.isEmpty
        else { return nil }
        return [
          "handle": value,
          "isPending": pending,
          "nickname": (try? IMCoreRuntime.string(member, "nickname")) as Any,
        ].compactMapValues { $0 is NSNull ? nil : $0 }
      }
    }
    return decode(try? IMCoreRuntime.send(conversation, "pendingMembers"), pending: true)
      + decode(try? IMCoreRuntime.send(conversation, "remoteMembers"), pending: false)
  }
}
