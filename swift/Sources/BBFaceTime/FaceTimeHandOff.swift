//  FaceTimeHandOff
//  Admitting joiners and deciding when the Mac may leave a call it placed or answered.
//
//  Flows B (dial, hand back a link) and C (answer, hand back a link) both end the same way: the
//  Mac is a participant in a call it does not want to be in, and it must leave — but not before
//  a real client has joined, or the call collapses on the person at the other end.
//
//  WHY THE DROP IS A POLL, NOT A TIMER. The Node server reads the macOS notification database
//  and parses serialised join notifications to know when someone joined — the "almost never
//  works" hack. Here the helper exposes typed membership, so the drop is gated on an actual
//  member appearing, polled, with a hard timeout. When the helper's membership EVENT proves
//  reliable on-device, the poll can be replaced by it.
//
//  A decision about live calls, so it lives here rather than in a handler — and
//  `FaceTimeCoordinator` owns the task, so stopping the Private API stops the watcher.

import BBPrivateAPIContract
import Foundation
import Logging

enum FaceTimeHandOff {

  /// The Mac may never leave a call with fewer than this many joined remotes behind it —
  /// FaceTime does not keep a call alive below two participants.
  ///
  /// THE COUNT IS THE WHOLE POINT, and getting it wrong hangs up on a real person. On a 1:1
  /// call the participants are the Mac and the callee, so "leave once a real participant has
  /// joined" was satisfied the instant the callee ANSWERED, and leaving then collapsed the
  /// call on them. Measured on a live call. The Mac may only leave once the client has ALSO
  /// joined: callee plus client, two remotes.
  static let remotesRequiredBeforeLeaving = 2

  /// How long the Mac waits for the hand-off to complete before giving up and staying.
  ///
  /// Two humans have to act inside this window — the callee answers, and only then does the
  /// requesting client open the link and join. Five minutes covers a realistic answer-then-join
  /// without holding a forgotten link open for anything like as long as the call would run.
  static let timeout: Duration = .seconds(300)

  /// How often membership is re-read.
  static let pollInterval: Duration = .seconds(1)

  /// Loose handle comparison.
  ///
  /// Membership may report a number in a different format from the one dialled
  /// (`+12025550143` vs `2025550143`), and an email in any casing, so an exact string match
  /// would fail to recognise a person we called.
  static func sameHandle(_ a: String, _ b: String) -> Bool {
    if a.caseInsensitiveCompare(b) == .orderedSame { return true }
    let digits = { (s: String) in s.filter(\.isNumber) }
    let (da, db) = (digits(a), digits(b))
    // Compare by the last 10 digits, which is what survives country-code differences.
    guard da.count >= 7, db.count >= 7 else { return false }
    return da.suffix(10) == db.suffix(10)
  }

  /// Whether the Mac may leave, given who is in the conversation right now.
  ///
  /// Pure, so the rule can be tested without a call. Two conditions, both required:
  ///
  ///   - **The client joined.** The client is the participant we did NOT dial — identifying
  ///     it that way rather than by a raw count is what makes GROUP calls correct: dialling
  ///     three people and waiting for "two remotes" would fire as soon as the second CALLEE
  ///     answered. A guest who came in by link has no FaceTime address (a throwaway
  ///     `temp:<uuid>` handle), so `isLightweight` identifies the client directly. With no
  ///     dialled list — an answered incoming call — any two active remotes will do.
  ///   - **Enough remotes remain.** So the call survives the Mac leaving.
  ///
  /// Only ACTIVE members count. A browser appears on the roster the moment it opens the link,
  /// while the person is still at "Waiting to be let in…"; counting those let the Mac leave
  /// before anyone had really joined, and the call died.
  static func mayLeave(members: [FaceTimeMember], dialledAddresses: [String]) -> Bool {
    let joined = members.filter(\.isActive)
    guard joined.count >= remotesRequiredBeforeLeaving else { return false }
    guard !dialledAddresses.isEmpty else { return true }
    return joined.contains { member in
      member.isLightweight
        || !dialledAddresses.contains { sameHandle($0, member.handle.value) }
    }
  }

  /// Admits anyone knocking, waits until the Mac is genuinely surplus, then drops it.
  ///
  /// Best-effort: every failure degrades to "the Mac stays in the call until a human hangs
  /// up", never to a crash. Honours cancellation, so a coordinator being torn down stops the
  /// watcher rather than leaving it polling a helper that is gone.
  static func run(
    api: any PrivateAPI,
    callUUID: String,
    conversationUUID: String,
    dialledAddresses: [String],
    logger: Logger
  ) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline, !Task.isCancelled {
      // STOP IF THE CALL IS GONE. Someone cancelling from a client, or the callee
      // declining, ends the call — and there is nothing left to hand off. Polling on
      // regardless kept re-asserting mute and re-admitting members against a call that
      // no longer existed, for the full timeout.
      //
      // A failed status check is NOT treated as "gone": that would abandon the hand-off
      // on one dropped request and leave the Mac in a live call forever.
      if let status = try? await api.faceTimeCallStatus(callUUID: callUUID),
        status == .disconnected
      {
        logger.info(
          "FaceTime call ended before hand-off; the watcher is stopping",
          metadata: ["call": .string(callUUID)])
        return
      }

      let members = (try? await api.faceTimeMembers(conversationUUID: conversationUUID)) ?? []

      // Re-assert mute every poll. It does not stick while the call is still ringing, so
      // applying it once at dial left the Mac's camera and microphone live for the callee.
      // Cheap, idempotent, and it catches the moment the call connects.
      _ = try? await api.silenceFaceTimeCall(callUUID: callUUID)

      // ADMIT anyone knocking. A link-joiner sits at "Waiting to be let in…" until the host
      // approves; nothing else in this system will do it. Retried every poll rather than
      // once, because an admit can land before the daemon has registered the knock.
      for waiting in members where !waiting.isActive {
        try? await api.admitFaceTimeParticipant(
          conversationUUID: conversationUUID, handle: waiting.handle.value
        )
      }

      if mayLeave(members: members, dialledAddresses: dialledAddresses) {
        // A short grace so the newest join is fully established before teardown.
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        try? await api.leaveFaceTimeCall(callUUID: callUUID)
        logger.info(
          "FaceTime hand-off complete; the Mac left the call",
          metadata: [
            "call": .string(callUUID),
            "remotes": .stringConvertible(members.filter(\.isActive).count),
          ])
        return
      }

      try? await Task.sleep(for: pollInterval)
    }

    guard !Task.isCancelled else { return }
    // TIMED OUT — and the Mac deliberately STAYS. Leaving here would hang up on whoever did
    // answer, which is the opposite of a safe default: the failure mode of staying is an idle
    // participant a human can hang up on, while the failure mode of leaving is ending a live
    // call between real people. The call is reported, not severed.
    logger.warning(
      "FaceTime hand-off timed out before the client joined; the Mac stays in the call rather than hanging up on the other party",
      metadata: ["call": .string(callUUID)]
    )
  }
}
