//  AlertStoring
//  Where the alert centre keeps its rows.
//
//  A protocol here rather than a database over there, because `BBDiagnostics` deliberately
//  depends on nothing but `BBCore` and swift-log — the alert centre is reachable
//  from every layer, and giving it a storage dependency would drag SQLite into all of them.
//  The concrete store lives beside the other repositories, next to the database it writes to.
//
//  Every method is allowed to throw and every caller treats a failure as non-fatal. An alert
//  that could not be written is still raised, still broadcast and still shown; the only thing
//  lost is that it will not survive a restart. Failing the raise instead would mean a storage
//  problem could suppress the notification telling you about it.

import Foundation

public protocol AlertStoring: Sendable {

  /// Alerts worth restoring: not dismissed, and newer than the retention cutoff.
  ///
  /// - Returns: the stored alerts, newest first, each carrying the `sequence` its row was
  ///   assigned.
  func restore(since cutoff: Date, limit: Int) async throws -> [UserAlert]

  /// Stores a newly raised alert.
  ///
  /// - Returns: the row's autoincrement id, which becomes the alert's `sequence`.
  func insert(_ alert: UserAlert) async throws -> Int

  /// Persists a change to an alert already stored — a recurrence bumping its count, or the
  /// user reading it.
  func update(_ alert: UserAlert) async throws

  func delete(_ id: UUID) async throws
  func deleteAll() async throws

  /// Drops rows past the retention window, and trims the oldest beyond `capacity`.
  func prune(before cutoff: Date, keeping capacity: Int) async throws
}
