//  FaceTimeCleanupReportingTests
//  What the cleanup CLAIMS it did has to be what it did.
//
//  The leave was a `try?` with an unconditional append after it, so a helper that refused
//  still produced `leftCalls: [the call]`. `POST facetime/cleanup` answered with the call in
//  that array and the settings button said it had left one. The single thing a person uses
//  this for is getting the Mac out of a call, and it reported success for the one case where
//  that did not happen: the Mac sits in somebody's conversation and the server says it left.
//
//  The `failure` field on the result exists for exactly this, and was documented as existing
//  for exactly this, and the call path never wrote to it.

import BBPrivateAPIContract
import BBSystem
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BBFaceTime

@Suite("FaceTime cleanup reporting")
struct FaceTimeCleanupReportingTests {

  private func answeredCall(_ uuid: String) -> FaceTimeCall {
    FaceTimeCall(callUUID: uuid, status: .answered)
  }

  /// Reports one answered call; `onLeaveCall` decides whether it can be left.
  private func api(
    reporting uuid: String,
    leave: (@Sendable (String) async throws -> Void)?
  ) -> FailingPrivateAPI {
    var api = FailingPrivateAPI()
    let call = answeredCall(uuid)
    api.onActiveCalls = { [call] }
    api.onLeaveCall = leave
    return api
  }

  /// A ledger in a throwaway location: the real one lives in Application Support and a test
  /// must never sweep a developer's own links.
  private static func emptyLedger() -> FaceTimeLinkLedger {
    FaceTimeLinkLedger(
      path: NSTemporaryDirectory() + "bb-ledger-\(UUID().uuidString).json")
  }

  @Test("A refused leave is not reported as a departure")
  func refusedLeaveIsNotClaimed() async {
    // `onLeaveCall` nil means the fixture throws, which is a wedged helper: the state this
    // button exists to recover from.
    let result = await FaceTimeCleanup.run(
      api: api(reporting: "CALL-1", leave: nil),
      ledger: Self.emptyLedger(), scope: .all, leaveUntrackedCalls: true,
      protectedCalls: [], logger: Logger(label: "test")
    )

    #expect(result.leftCalls.isEmpty, "a call the helper refused to leave was reported as left")
    #expect(result.failure != nil, "the refusal has to be reported, not swallowed")
  }

  @Test("A successful leave is still reported")
  func successfulLeaveIsClaimed() async {
    // The other half: tightening the claim must not stop it being made when it is true.
    let left = Locked<[String]>([])
    let result = await FaceTimeCleanup.run(
      api: api(reporting: "CALL-2", leave: { uuid in left.mutate { $0.append(uuid) } }),
      ledger: Self.emptyLedger(), scope: .all, leaveUntrackedCalls: true,
      protectedCalls: [], logger: Logger(label: "test")
    )

    #expect(result.leftCalls == ["CALL-2"])
    #expect(left.value == ["CALL-2"])
  }

  @Test("A protected call is never left")
  func protectedCallsAreUntouched() async {
    // A call with a live hand-off watcher is mid-join, and leaving it hangs up on a real
    // conversation. Worth pinning here because `protectedCalls` is fed by the coordinator
    // map whose identity bug could empty it; see `HandOffIdentityTests`.
    let left = Locked<[String]>([])
    let result = await FaceTimeCleanup.run(
      api: api(reporting: "CALL-3", leave: { uuid in left.mutate { $0.append(uuid) } }),
      ledger: Self.emptyLedger(), scope: .all, leaveUntrackedCalls: true,
      protectedCalls: ["CALL-3"], logger: Logger(label: "test")
    )

    #expect(result.leftCalls.isEmpty)
    #expect(left.value.isEmpty, "a protected call must not even be attempted")
  }
}

/// A tiny box so a `@Sendable` closure can record what it was asked to do.
private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
