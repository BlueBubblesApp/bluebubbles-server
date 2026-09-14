//  PermissionStreamSeedTests
//  A new subscriber is told what is already known, not only what changes next.
//
//  REGRESSION. `stream()` registered an observer and yielded nothing, so a subscriber's first
//  answer arrived on the next broadcast — which, with nobody looking at a permission page, is
//  the IDLE cadence away: sixty seconds.
//
//  What that cost: `PermissionsModel.unsatisfiedRequiredCount` reads
//  `statuses[id] ?? .notDetermined`, and exactly ONE permission in the catalogue is
//  `.required`, so an empty map and "Full Disk Access is missing" are the same number. Home
//  opened reporting one required permission missing on a Mac that had granted it. Opening the
//  Permissions page set `isWatched`, which re-checks immediately, which broadcast — so that
//  page was green and Home was correct on the way back, and the whole thing read as a stale
//  count rather than as a first value that was never sent.
//
//  In a separate file from `PermissionsTests` deliberately: this is about the SUBSCRIPTION,
//  not about the cadence rules that suite covers.

import BBServiceKit
import Foundation
import Testing

@testable import BBSystem

private actor SeedProbe: PermissionProbing {
  func fullDiskAccess() async -> PermissionStatus { .granted }
  func automation(bundleIdentifier: String) async -> PermissionStatus { .granted }
  func contacts() async -> PermissionStatus { .granted }
  func notifications() async -> PermissionStatus { .granted }
  func systemIntegrityProtectionDisabled() async -> PermissionStatus { .denied }
}

@Suite("Permission stream seeding")
struct PermissionStreamSeedTests {

  /// The first element arrives without waiting for a tick.
  ///
  /// BOUNDED, and that is not decoration. The regression is an element that never comes, and
  /// nothing in this service would ever send one: `startMonitoring` is not running here, so
  /// an unbounded `next()` waits for the heat death of the test run rather than failing. A
  /// regression test that hangs instead of failing is worse than no test — it stops the suite
  /// without saying what broke.
  @Test("A subscriber is seeded with the checks already made", .timeLimit(.minutes(1)))
  func subscriberIsSeeded() async throws {
    let service = PermissionsService(probe: SeedProbe())
    // What `startMonitoring` does immediately on start, before any UI exists.
    _ = await service.checkAll()

    let seeded = try #require(
      await Self.firstElement(of: await service.stream()),
      "a subscriber got nothing until the next broadcast, which is 60s away")
    #expect(seeded[.fullDiskAccess] == .granted)
  }

  /// The count Home renders, computed from a freshly seeded subscriber. This is the assertion
  /// that actually failed: one required permission, granted, reported as missing.
  @Test("The required permission reads as granted on the first element", .timeLimit(.minutes(1)))
  func theRequiredPermissionIsNotReportedMissing() async throws {
    let service = PermissionsService(probe: SeedProbe())
    _ = await service.checkAll()

    let statuses: [PermissionID: PermissionStatus] = try #require(
      await Self.firstElement(of: await service.stream()),
      "nothing was delivered, so the count Home renders had nothing to render from")

    // `permissions` is `nonisolated`, so no `await`.
    let catalogue: [Permission] = service.permissions
    let required = catalogue.filter { $0.requirement.isRequired }
    #expect(!required.isEmpty, "nothing is required any more; this test is asserting nothing")
    let missing = required.filter { permission in
      let status: PermissionStatus = statuses[permission.id] ?? .notDetermined
      return status != .granted
    }
    #expect(missing.isEmpty, "reported missing: \(missing.map { $0.title })")
  }

  /// Seeding must not invent an answer. Before anything has been checked there is nothing to
  /// say, and seeding "all unknown" would be the same wrong claim one step removed — it is
  /// what the empty map already meant to the count that was wrong.
  ///
  /// Asserted by racing the first element against a deadline, because the property is that
  /// NOTHING arrives: the iterator is driven inside one task so it is never captured across
  /// two.
  @Test("A subscriber that arrives before the first check is not seeded")
  func nothingCheckedMeansNothingSent() async throws {
    let service = PermissionsService(probe: SeedProbe())
    let stream = await service.stream()

    let arrived = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in stream { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(300))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    #expect(!arrived, "an unchecked service seeded a subscriber with a made-up answer")
  }

  /// The stream's first element, or nil if it does not arrive promptly.
  ///
  /// The deadline is what turns "never delivered" into a failing expectation rather than a
  /// hung suite. Generous relative to the work (the element is already buffered when the
  /// behaviour is correct) and tiny relative to the 60-second broadcast a regression would
  /// otherwise wait for.
  /// Wraps the element so "the stream produced nothing" and "the deadline won" are the same
  /// arm without a double optional, which is unreadable and was a compile error twice.
  private struct Delivered: Sendable {
    let statuses: [PermissionID: PermissionStatus]?
  }

  private static func firstElement(
    of stream: AsyncStream<[PermissionID: PermissionStatus]>
  ) async -> [PermissionID: PermissionStatus]? {
    await withTaskGroup(of: Delivered.self) { group in
      group.addTask {
        for await element in stream { return Delivered(statuses: element) }
        return Delivered(statuses: nil)
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return Delivered(statuses: nil)
      }
      let first = await group.next()
      group.cancelAll()
      return first?.statuses
    }
  }
}
