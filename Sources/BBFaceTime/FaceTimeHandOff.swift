//  FaceTimeHandOff
//  Admitting joiners and deciding when the Mac may leave a call it placed or answered.
//
//  Flows B (dial, hand back a link) and C (answer, hand back a link) both end the same way: the
//  Mac is a participant in a call it does not want to be in, and it must leave, but not before
//  a real client has joined, or the call collapses on the person at the other end.
//
//  WHY THE DROP IS A POLL, NOT A TIMER. The helper exposes typed membership, so the drop is
//  gated on an actual member appearing, polled, with a hard timeout. When the helper's
//  membership EVENT proves reliable on-device, the poll can be replaced by it.
//
//  WHAT IS LOGGED IS WHAT HAPPENED. "The Mac left the call" is said only after a leave that
//  returned, and a membership read that failed is never read as an empty call: either claim,
//  made falsely, tells a person the Mac is out of a conversation it is still sitting in, or
//  that nobody joined a call the server could not see into. `Outcome` carries the same answer
//  so a test can hold it.
//
//  A decision about live calls, so it lives here rather than in a handler, and
//  `FaceTimeCoordinator` owns the task, so stopping the Private API stops the watcher.

import BBCore
import BBPrivateAPIContract
import Foundation
import Logging

enum FaceTimeHandOff {

  /// The Mac may never leave a call with fewer than this many joined remotes behind it:
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
  /// Two humans have to act inside this window: the callee answers, and only then does the
  /// requesting client open the link and join. Five minutes covers a realistic answer-then-join
  /// without holding a forgotten link open for anything like as long as the call would run.
  static let timeout: Duration = .seconds(300)

  /// How often membership is re-read.
  static let pollInterval: Duration = .seconds(1)

  /// A short grace after the deciding join, so the newest member is fully established before
  /// the Mac's own teardown.
  static let leaveGrace: Duration = .seconds(3)

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
  ///   - **The client joined.** The client is the participant we did NOT dial; identifying
  ///     it that way rather than by a raw count is what makes GROUP calls correct: dialling
  ///     three people and waiting for "two remotes" would fire as soon as the second CALLEE
  ///     answered. A guest who came in by link has no FaceTime address (a throwaway
  ///     `temp:<uuid>` handle), so `isLightweight` identifies the client directly. With no
  ///     dialled list (an answered incoming call) any two active remotes will do.
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

  /// How a hand-off ended.
  enum Outcome: Equatable, Sendable {
    /// The helper reported the leave as done. The only outcome that says the Mac is out.
    case left
    /// The call ended on its own before the hand-off completed.
    case callEnded
    /// The coordinator cancelled the watcher.
    case cancelled
    /// The deadline passed and the Mac is still in the call, for the stated reason.
    case stayed(Obstacle)
  }

  /// What stood between the hand-off and the Mac leaving when the deadline passed.
  ///
  /// The most recent one, because that is what was still true at the end: a membership read
  /// that failed once and then recovered is not why a client never arrived.
  enum Obstacle: Equatable, Sendable {
    /// Membership was read and the client never joined. The ordinary timeout.
    case clientNeverJoined
    /// Membership could not be read, so whether anyone joined is unknown.
    case membershipUnreadable
    /// The client joined and the helper refused to take the Mac out of the call.
    case leaveRefused
  }

  /// Admits anyone knocking, waits until the Mac is genuinely surplus, then drops it.
  ///
  /// Best-effort: every failure degrades to "the Mac stays in the call until a human hangs
  /// up", never to a crash. Honours cancellation, so a coordinator being torn down stops the
  /// watcher rather than leaving it polling a helper that is gone. A refused leave is retried
  /// on the next poll, so one dropped request does not strand the Mac in the call.
  ///
  /// The loop is `poll`, every `pollInterval` within `timeout`: each attempt either ends the
  /// hand-off with an `Outcome` or answers nil to be asked again, and records what stood in
  /// the way so a deadline that passes can say. Every wait, the leave grace included, is on
  /// `clock`, which tests replace; the coordinator takes the default.
  @discardableResult
  static func run<C: Clock<Duration>>(
    api: any PrivateAPI,
    callUUID: String,
    conversationUUID: String,
    dialledAddresses: [String],
    logger: Logger,
    clock: C = ContinuousClock()
  ) async -> Outcome {
    var obstacle = Obstacle.clientNeverJoined
    /// The error behind `obstacle`, already redacted, for the timeout warning.
    var obstacleError: String?

    let finished: Outcome?
    do {
      finished = try await poll(.every(pollInterval), within: timeout, clock: clock) { _ in
        guard !Task.isCancelled else { return Outcome.cancelled }

        // STOP IF THE CALL IS GONE. Someone cancelling from a client, or the callee
        // declining, ends the call, and there is nothing left to hand off. Polling on
        // regardless would keep re-asserting mute and re-admitting members against a call
        // that no longer exists, for the full timeout.
        //
        // A failed status check is NOT treated as "gone": that would abandon the hand-off
        // on one dropped request and leave the Mac in a live call forever. Its failure is
        // reported by the membership read below, which asks the same helper.
        if let status = try? await api.faceTimeCallStatus(callUUID: callUUID),
          status == .disconnected
        {
          logger.info(
            "FaceTime call ended before hand-off; the watcher is stopping",
            metadata: ["call": .string(callUUID)])
          return .callEnded
        }

        // Re-assert mute every poll. It does not stick while the call is still ringing, so
        // applying it once at dial left the Mac's camera and microphone live for the callee.
        // Cheap and idempotent; a failure goes to the next poll, which asserts it again.
        _ = try? await api.silenceFaceTimeCall(callUUID: callUUID)

        let members: [FaceTimeMember]
        do {
          members = try await api.faceTimeMembers(conversationUUID: conversationUUID)
          obstacle = .clientNeverJoined
          obstacleError = nil
        } catch {
          // NOT an empty call. Nothing is admitted or decided on a roster that was not read;
          // the next poll asks again, and a deadline that passes first says it could not see.
          obstacle = .membershipUnreadable
          obstacleError = Redaction.error(error)
          logger.debug(
            "Could not read FaceTime call membership; retrying",
            metadata: ["call": .string(callUUID), "error": .string(Redaction.error(error))])
          return nil
        }

        // ADMIT anyone knocking. A link-joiner sits at "Waiting to be let in…" until the host
        // approves; nothing else in this system will do it. Retried every poll rather than
        // once, because an admit can land before the daemon has registered the knock.
        for waiting in members where !waiting.isActive {
          do {
            try await api.admitFaceTimeParticipant(
              conversationUUID: conversationUUID, handle: waiting.handle.value
            )
          } catch {
            // Retried next poll; logged so a guest stuck at "Waiting to be let in…" can be
            // explained. The handle is the guest's address, so it is redacted.
            logger.debug(
              "Could not admit a FaceTime participant",
              metadata: [
                "call": .string(callUUID),
                "handle": .string(Redaction.address(waiting.handle.value)),
                "error": .string(Redaction.error(error)),
              ])
          }
        }

        guard mayLeave(members: members, dialledAddresses: dialledAddresses) else { return nil }
        // The grace's only failure is cancellation, which is this watcher being stopped.
        do { try await clock.sleep(for: leaveGrace) } catch { return .cancelled }
        do {
          try await api.leaveFaceTimeCall(callUUID: callUUID)
          logger.info(
            "FaceTime hand-off complete; the Mac left the call",
            metadata: [
              "call": .string(callUUID),
              "remotes": .stringConvertible(members.filter(\.isActive).count),
            ])
          return .left
        } catch {
          // The Mac is still in the call: nothing claims otherwise and the watcher keeps
          // going. The next poll re-checks membership and tries again, and a deadline that
          // passes first reports the refusal by name.
          obstacle = .leaveRefused
          obstacleError = Redaction.error(error)
          logger.debug(
            "Could not leave the FaceTime call after hand-off; retrying",
            metadata: ["call": .string(callUUID), "error": .string(Redaction.error(error))])
          return nil
        }
      }
    } catch {
      // `poll` throws only what an attempt throws, and none does, or a cancellation during
      // its wait between attempts: the coordinator stopping this watcher.
      return .cancelled
    }
    if let finished { return finished }

    // TIMED OUT, and the Mac deliberately STAYS. Leaving here would hang up on whoever did
    // answer, which is the opposite of a safe default: the failure mode of staying is an idle
    // participant a human can hang up on, while the failure mode of leaving is ending a live
    // call between real people. The call is reported, not severed, and the report names
    // which of the three things kept the Mac in it.
    var metadata: Logger.Metadata = ["call": .string(callUUID)]
    if let obstacleError { metadata["error"] = .string(obstacleError) }
    switch obstacle {
    case .clientNeverJoined:
      logger.warning(
        "FaceTime hand-off timed out before the client joined; the Mac stays in the call rather than hanging up on the other party",
        metadata: metadata)
    case .membershipUnreadable:
      logger.warning(
        "FaceTime hand-off timed out because the call's membership could not be read; the Mac stays in the call, since whether the client joined is unknown",
        metadata: metadata)
    case .leaveRefused:
      logger.warning(
        "FaceTime hand-off could not leave the call: the client joined but every leave was refused; the Mac is still in the call",
        metadata: metadata)
    }
    return .stayed(obstacle)
  }
}
