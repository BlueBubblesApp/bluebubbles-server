//  FaceTimeCleanup
//  Clearing up after ourselves: stray links, and calls the Mac is stuck in.
//
//  WHEN IT RUNS. On the FaceTime helper registering (server start, or either app restarting),
//  and on demand from `POST facetime/cleanup` and the settings button.
//
//  Helper registration is not an arbitrary hook: it is the ONLY moment link cleanup can work.
//  Invalidation needs `TUConversationLink` objects, and the only source that yields them
//  (`activatedConversationLinks`) is populated at process start and never refreshed, because
//  the data-source delegate that would refresh it crashes FaceTime.app. See
//  docs/headers/FACETIME.md. A link minted after that snapshot is not invalidatable until the
//  next restart, which is why strays accumulate and why the sweep happens here.
//
//  WHAT IT WILL NOT DO. It only ever invalidates links recorded in `FaceTimeLinkLedger`:
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
    /// Blocking alerts cancelled: recovery for a wedged FaceTime.app.
    var dismissedAlerts = 0
    /// Present when something was attempted and failed: reported rather than swallowed,
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
  /// - Parameter protectedCalls: calls with a live hand-off watcher. NEVER left: the
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
    /// Everything that went wrong, joined into `result.failure` on the way out.
    ///
    /// Accumulated rather than assigned, because each stage used to overwrite the field: a
    /// link sweep that failed erased the reason a CALL could not be left, and the caller was
    /// told about whichever happened to run last. The stages are independent and a partial
    /// result should say so about every part.
    var failures: [String] = []

    /// The one exit, so a failure recorded before an early return is still reported. The
    /// links section returns early when there is nothing to sweep, which is exactly the case
    /// where a failed call-leave was the only thing worth saying.
    func finish() -> Result {
      var result = result
      if !failures.isEmpty { result.failure = failures.joined(separator: "; ") }
      return result
    }

    // ---- A blocking alert first, because it wedges everything after it.
    //
    // Dialling an address FaceTime cannot reach puts up "…is not available for FaceTime",
    // which the pre-flight now prevents, but if one appears any other way, an app stuck
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
          // Appended ONLY on success. The leave was a `try?` with an unconditional append
          // after it, so a helper that refused produced a result claiming the Mac had left
          // a call it was still sitting in: `POST facetime/cleanup` answered with the call
          // in `leftCalls`, and the settings button said "left 1 call". The one thing a
          // person uses this for is getting the Mac OUT of a call, and it reported success
          // for the case where that did not happen.
          do {
            try await api.leaveFaceTimeCall(callUUID: call.callUUID)
            result.leftCalls.append(call.callUUID)
          } catch {
            // Recorded in the field that exists for it rather than thrown: the other calls
            // and the links still want sweeping, and a partial result that SAYS it is
            // partial is more useful than an exception that abandons the rest.
            failures.append("could not leave a call: \(error)")
          }
        }
      } catch {
        failures.append("could not read active calls: \(error)")
      }
    }

    // ---- Then links.
    let candidates: [FaceTimeLinkLedger.Entry]
    switch scope {
    case .expired(let age): candidates = await ledger.expired(olderThan: age)
    case .all: candidates = await ledger.all()
    }
    guard !candidates.isEmpty else { return finish() }

    do {
      // The URL list is passed explicitly, so the helper invalidates ONLY these: never
      // whatever else happens to be in FaceTime's link list.
      let invalidated = try await api.invalidateFaceTimeLinks(
        urls: candidates.map(\.url)
      )
      result.invalidatedLinks = invalidated
      // Forget only what was actually invalidated: a link that failed stays on the
      // ledger and is retried on the next sweep rather than being silently abandoned.
      await ledger.forget(urls: invalidated)

      // Candidates but nothing invalidated is NOT "nothing to clean up". It means the
      // links are not in FaceTime.app's current link snapshot (taken at process start
      // and never refreshed) so they cannot be acted on until it restarts. Reported,
      // because the two outcomes are otherwise identical from outside and the caller
      // would be told the strays were gone.
      if invalidated.isEmpty {
        failures.append(
          "\(candidates.count) link(s) could not be invalidated yet: "
            + "they are not in FaceTime's current link list, which only refreshes when "
            + "FaceTime restarts. Restart FaceTime and try again."
        )
      }
    } catch {
      // Expected whenever the links are not in FaceTime's current snapshot: they
      // become invalidatable after the next restart, and they stay on the ledger.
      failures.append("could not invalidate \(candidates.count) link(s): \(error)")
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
    return finish()
  }
}
