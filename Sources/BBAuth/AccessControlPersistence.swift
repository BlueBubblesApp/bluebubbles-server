//  AccessControlPersistence
//  The durable half of access control, and the one lane that writes it.
//
//  An allowlist an administrator curated must survive a restart or it is worse than useless,
//  and a blocklist that does not survive makes "restart the server" an accidental
//  unblock-everyone button. The writes are fire-and-forget from the request that caused them,
//  because a failed write must never fail that request, but they are not unordered: one writer
//  re-reads the live state each pass, so a block followed by its unblock can never land in the
//  other order and come back blocked after a restart.
//
//  See `docs/AUTH.md`.

import Foundation
import Logging

/// Durable storage for the administered half of access control.
///
/// A protocol rather than a direct dependency so BBAuth does not have to know about GRDB:
/// the implementation lives with the rest of the app's storage.
public protocol AccessControlPersistence: Sendable {
  func loadAccessControl() async throws -> (blocked: [BlockedClient], allowlist: [AllowedClient])
  func saveBlocked(_ blocked: [BlockedClient]) async throws
  func saveAllowlist(_ allowlist: [AllowedClient]) async throws

  /// The recent-failure ring, newest last, already bounded by the caller.
  ///
  /// Separate from `loadAccessControl` rather than folded into its tuple because the two
  /// are restored differently and it matters: blocks come back as ENFORCEMENT and these
  /// come back as EVIDENCE. See `AccessControlService.loadPersistedState`.
  ///
  /// No default implementation, deliberately. A defaulted no-op would let a conformer look
  /// complete while silently dropping every failure, which is the shape this whole change
  /// exists to remove.
  func loadFailures(limit: Int) async throws -> [AuthFailureRecord]
  func saveFailures(_ failures: [AuthFailureRecord]) async throws
}

/// The persistence lane's bookkeeping: what still needs writing, and the tasks doing it.
///
/// FLAGS, not snapshots. Each write rewrites its whole table, so what a write should contain
/// is "the state as it is when the write runs", and taking it then, inside the actor, is what
/// makes a stale snapshot unrepresentable rather than merely unlikely.
struct AccessControlWriteLane {
  var blockedNeedsWrite = false
  var allowlistNeedsWrite = false
  var failuresNeedsWrite = false
  /// The one task writing. Nil when nothing is.
  var writer: Task<Void, Never>?

  /// The debounce in front of the failure table, and the task serving it.
  ///
  /// Blocks and allowlist entries change when a person or a threshold acts, so writing one
  /// per change is bounded by events. **Failures are different in kind: their arrival rate is
  /// chosen by whoever is attacking.** A write per failure would hand an attacker a
  /// `DELETE`-plus-500-`INSERT` table rewrite per guess: the server doing far more work than
  /// the attacker, on the disk, on the exact path that is already under attack.
  ///
  /// So the first failure arms a timer and every failure inside that window rides along free:
  /// sustained guessing costs one rewrite per interval no matter how fast it comes. The cost
  /// is losing up to one interval of failures on a hard kill, which is the right trade for
  /// evidence. A clean stop loses nothing, because `flushPersistedState` spends the timer
  /// rather than waiting it out.
  var failureWriteTask: Task<Void, Never>?
  static let failureWriteInterval: Duration = .seconds(5)

  var hasWork: Bool { blockedNeedsWrite || allowlistNeedsWrite || failuresNeedsWrite }
}

extension AccessControlService {

  /// Reads the durable state back in. Called once, at startup, before anything is served.
  public func loadPersistedState() async {
    guard let persistence else { return }
    do {
      let state = try await persistence.loadAccessControl()
      let failures = try await persistence.loadFailures(limit: policy.failureHistoryLimit)
      restore(blocked: state.blocked, allowlist: state.allowlist, failures: failures)
    } catch {
      // Not fatal, and deliberately so: a server that refuses to start because it
      // could not read its blocklist has turned a minor problem into an outage.
      logger.warning(
        "Could not restore access control state",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  /// Marks state as needing a write, and makes sure something is writing.
  ///
  /// Fire-and-forget from the caller's side, and ordered all the same. A snapshot per call,
  /// each written by its own task, let a block and the unblock that followed it land in
  /// either order: "I unblocked that address, and after a restart it was blocked again",
  /// security state reverting on its own. ONE writer that re-reads the live state each pass
  /// means the last write always carries the newest state. It also coalesces: ten blocks in
  /// a burst are one or two table rewrites rather than ten, which matters because each one
  /// is a `DELETE`-then-`INSERT` over the whole table.
  func persist(
    blocked persistBlocked: Bool = false,
    allowlist persistAllow: Bool = false,
    failures persistFailures: Bool = false
  ) {
    guard persistence != nil else { return }
    lane.blockedNeedsWrite = lane.blockedNeedsWrite || persistBlocked
    lane.allowlistNeedsWrite = lane.allowlistNeedsWrite || persistAllow
    lane.failuresNeedsWrite = lane.failuresNeedsWrite || persistFailures
    guard lane.writer == nil else { return }
    lane.writer = Task { [weak self] in await self?.drainWrites() }
  }

  /// Arms the failure debounce, or rides an already-armed one.
  ///
  /// Nothing is marked dirty here: the flag is set when the timer fires, so a failure
  /// arriving while a write is in flight cannot be mistaken for one already included in it.
  /// See `AccessControlWriteLane.failureWriteTask`.
  func persistFailuresSoon() {
    guard persistence != nil, lane.failureWriteTask == nil else { return }
    lane.failureWriteTask = Task { [weak self] in
      try? await Task.sleep(for: AccessControlWriteLane.failureWriteInterval)
      // Cancelled means `flushPersistedState` is writing it now instead.
      guard !Task.isCancelled else { return }
      await self?.fireFailureWrite()
    }
  }

  private func fireFailureWrite() {
    lane.failureWriteTask = nil
    persist(failures: true)
  }

  /// Writes whatever is outstanding, one pass at a time, until nothing is.
  ///
  /// Re-entrancy is the point rather than a hazard: the `await` on the store lets another
  /// request run and set the flags again, and the loop picks that up on its next pass with
  /// the state as it then is. The flags are cleared BEFORE the write so a change arriving
  /// during one is not mistaken for having been included in it.
  private func drainWrites() async {
    guard let persistence else { return }
    defer { lane.writer = nil }
    while lane.hasWork {
      let writeBlocked = lane.blockedNeedsWrite
      let writeAllowlist = lane.allowlistNeedsWrite
      let writeFailures = lane.failuresNeedsWrite
      lane.blockedNeedsWrite = false
      lane.allowlistNeedsWrite = false
      lane.failuresNeedsWrite = false
      // Read here, inside the actor, immediately before the write.
      let blockedNow = Array(blocked.values)
      let allowlistNow = allowlist
      let failuresNow = recentFailures
      do {
        if writeBlocked { try await persistence.saveBlocked(blockedNow) }
        if writeAllowlist { try await persistence.saveAllowlist(allowlistNow) }
        if writeFailures { try await persistence.saveFailures(failuresNow) }
      } catch {
        // Logged and dropped. The next change rewrites the whole table anyway,
        // so a failed write costs durability until the next one rather than consistency.
        logger.warning(
          "Could not persist access control state",
          metadata: [
            "error": .string(String(describing: error))
          ])
      }
    }
  }

  /// Waits until nothing is queued to be written.
  ///
  /// For tests, and for any caller that needs the durable state to be current before it
  /// looks at it. Loops rather than awaiting once: a write can enqueue another while it is
  /// running, and "settled" means no writer at all.
  public func flushPersistedState() async {
    // The armed debounce is SPENT rather than waited out, so a clean stop keeps the
    // failures it was holding and a test does not pay five seconds to see them.
    if let pending = lane.failureWriteTask {
      pending.cancel()
      lane.failureWriteTask = nil
      persist(failures: true)
    }
    // `drainWrites` clears `writer` on its way out, so the loop ends when the last one
    // does; a write that enqueued another is awaited on the next turn.
    while let writer = lane.writer { await writer.value }
  }
}
