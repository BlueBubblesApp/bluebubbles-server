//  FaceTimeCleanup
//  Clearing up after ourselves: stray links, and calls the Mac is stuck in.
//
//  WHEN IT RUNS. On the FaceTime helper registering (server start, or either app restarting),
//  and on demand from `POST facetime/cleanup` and the settings button.
//
//  Helper registration is not an arbitrary hook — it is the ONLY moment link cleanup can work.
//  Invalidation needs `TUConversationLink` objects, and the only source that yields them
//  (`activatedConversationLinks`) is populated at process start and never refreshed, because
//  the data-source delegate that would refresh it crashes FaceTime.app. See
//  docs/headers/FACETIME.md. A link minted after that snapshot is not invalidatable until the
//  next restart, which is why strays accumulate and why the sweep happens here.
//
//  WHAT IT WILL NOT DO. It only ever invalidates links recorded in `FaceTimeLinkLedger` —
//  never one the user made in FaceTime.app. TelephonyUtilities cannot tell the two apart
//  (`locallyCreated` is true for both), so the ledger is the only safe basis, and deleting
//  somebody's own link is unrecoverable.

import BBPrivateAPIContract
import BBSettings
import BBSystem
import Foundation
import Logging

enum FaceTimeCleanup {

  struct Result: Sendable {
    var invalidatedLinks: [String] = []
    var leftCalls: [String] = []
    /// Blocking alerts cancelled — recovery for a wedged FaceTime.app.
    var dismissedAlerts = 0
    /// Present when something was attempted and failed — reported rather than swallowed,
    /// because an empty result is otherwise indistinguishable from "nothing to do".
    var failure: String?
  }

  enum Scope: Sendable {
    /// Links older than the TTL. The automatic sweep.
    case expired(TimeInterval)
    /// Every ledgered link, now. The settings button.
    case all
  }

  /// Sweeps stray links and, optionally, leaves calls the server is not managing.
  ///
  /// - Parameter protectedCalls: calls with a live hand-off watcher. NEVER left — the
  ///   watcher is mid-flight and leaving underneath it would hang up on a real conversation.
  static func run(
    api: any PrivateAPI,
    ledger: FaceTimeLinkLedger,
    scope: Scope,
    leaveUntrackedCalls: Bool,
    protectedCalls: Set<String>,
    logger: Logger
  ) async -> Result {
    var result = Result()

    // ---- A blocking alert first, because it wedges everything after it.
    //
    // Dialling an address FaceTime cannot reach puts up "…is not available for FaceTime",
    // which the pre-flight now prevents — but if one appears any other way, an app stuck
    // behind a modal is an app that cannot be driven. CANCELS rather than confirms: the
    // alert's other buttons offer to call a DIFFERENT address on the contact card, and
    // confirming could place a call nobody asked for.
    //
    // Folded in here rather than exposed as its own route: it is recovery, not something
    // a client should be able to trigger.
    result.dismissedAlerts = (try? await api.dismissFaceTimeAlert()) ?? 0

    // ---- Calls first. A stuck call is the more urgent problem: the Mac sits silently in
    // somebody's conversation until a human notices.
    if leaveUntrackedCalls {
      do {
        for call in try await api.faceTimeActiveCalls() {
          guard !protectedCalls.contains(call.callUUID) else { continue }
          // Only calls that are actually up. A ringing outgoing call may be one a
          // client started moments ago and the server has not finished recording.
          guard call.status == .answered else { continue }
          try? await api.leaveFaceTimeCall(callUUID: call.callUUID)
          result.leftCalls.append(call.callUUID)
        }
      } catch {
        result.failure = "could not read active calls: \(error)"
      }
    }

    // ---- Then links.
    let candidates: [FaceTimeLinkLedger.Entry]
    switch scope {
    case .expired(let age): candidates = await ledger.expired(olderThan: age)
    case .all: candidates = await ledger.all()
    }
    guard !candidates.isEmpty else { return result }

    do {
      // The URL list is passed explicitly, so the helper invalidates ONLY these — never
      // whatever else happens to be in FaceTime's link list.
      let invalidated = try await api.invalidateFaceTimeLinks(
        urls: candidates.map(\.url)
      )
      result.invalidatedLinks = invalidated
      // Forget only what was actually invalidated: a link that failed stays on the
      // ledger and is retried on the next sweep rather than being silently abandoned.
      await ledger.forget(urls: invalidated)

      // Candidates but nothing invalidated is NOT "nothing to clean up". It means the
      // links are not in FaceTime.app's current link snapshot — taken at process start
      // and never refreshed — so they cannot be acted on until it restarts. Reported,
      // because the two outcomes are otherwise identical from outside and the caller
      // would be told the strays were gone.
      if invalidated.isEmpty {
        result.failure =
          "\(candidates.count) link(s) could not be invalidated yet: "
          + "they are not in FaceTime's current link list, which only refreshes when "
          + "FaceTime restarts. Restart FaceTime and try again."
      }
    } catch {
      // Expected whenever the links are not in FaceTime's current snapshot — they
      // become invalidatable after the next restart, and they stay on the ledger.
      result.failure = "could not invalidate \(candidates.count) link(s): \(error)"
    }

    if !result.invalidatedLinks.isEmpty || !result.leftCalls.isEmpty
      || result.dismissedAlerts > 0
    {
      logger.info(
        "FaceTime cleanup",
        metadata: [
          "links": .stringConvertible(result.invalidatedLinks.count),
          "calls": .stringConvertible(result.leftCalls.count),
          "alerts": .stringConvertible(result.dismissedAlerts),
        ])
    }
    return result
  }
}
