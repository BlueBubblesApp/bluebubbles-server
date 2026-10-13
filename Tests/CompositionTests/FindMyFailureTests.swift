//  FindMyFailureTests
//  What a client receives when Messages refuses a FindMy operation.
//
//  The fifth exhaustive walk, and the last of the ones that needed a harness. Same contract
//  as its siblings: a refusal from Messages is `InterfaceError.messagesFailed`, projecting to
//  the 500 `iMessage Error`, never a generic server error.
//
//  **The gate is the reason this file is not just five lines.** `refreshFriends` and
//  `refreshLocation` sit behind `IntervalGate`s, and a gated call does not reach Messages at
//  all — it returns `.tooSoon` carrying the cache. So there are two properties here, and only
//  the second is about translation:
//
//    1. On the allowed path, a refusal translates. A fresh `FindMyRuntime` per test makes
//       this deterministic rather than timing-dependent: `IntervalGate.lastPassed` starts
//       nil, so the FIRST attempt is unconditionally allowed, whatever the clock says.
//    2. On the refused path, the operation must NOT report a Messages failure — because
//       Messages was never asked. A walk that only drove the allowed path would pass just as
//       happily if the gate were wired to refuse everything, and every FindMy refresh in the
//       product would silently stop reaching Apple with nothing failing.
//
//  That second one is the trap this file exists for, and it is the same shape as the empty
//  profile that hid nine message operations: an assertion about a code path that was never
//  entered looks exactly like a passing test.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBHTTPAPI
import BBPrivateAPIContract
import BBSystem
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("FindMy failure translation")
struct FindMyFailureTests {

  private static let handle = "person@example.com"
  private static let chat = ChatIdentifier("iMessage;-;person@example.com")

  /// A fresh runtime every time, so every gate starts open.
  private func interface(privateAPI: FindMyInterface.Helper? = FailingPrivateAPI())
    -> FindMyInterface
  {
    FindMyInterface(runtime: FindMyRuntime(), privateAPI: privateAPI)
  }

  /// Every FindMy operation that reaches Messages, by name, so a failure says which one.
  private func operations(
    _ findMy: FindMyInterface
  ) -> [(String, () async throws -> Void)] {
    [
      ("refreshFriends", { _ = try await findMy.refreshFriends() }),
      ("refreshLocation", { _ = try await findMy.refreshLocation(handle: Self.handle) }),
      ("requestShare", { try await findMy.requestShare(handle: Self.handle) }),
      (
        "startSharing",
        {
          try await findMy.startSharing(
            FindMyShareRequest(chat: Self.chat, duration: .oneHour))
        }
      ),
      ("stopSharing", { try await findMy.stopSharing(chat: Self.chat, address: nil) }),
    ]
  }

  @Test("Every FindMy operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    // One interface PER OPERATION, not one shared: two gated operations run here, and a
    // shared runtime would let the first exhaust a gate the second needs open.
    for (name, _) in operations(interface()) {
      let findMy = interface()
      guard let operation = operations(findMy).first(where: { $0.0 == name })?.1 else {
        Issue.record("\(name) disappeared between two builds of the table")
        return
      }
      do {
        try await operation()
        Issue.record("\(name) should have failed")
      } catch let error as InterfaceError {
        #expect(error == .messagesFailed("Messages said no"), "\(name)")
      } catch {
        Issue.record("\(name) threw \(type(of: error)) rather than InterfaceError: \(error)")
      }
    }
  }

  /// The rendered envelope, since that is what a client actually parses.
  @Test("A refused FindMy operation renders as 500 with the iMessage error type")
  func rendersWithTheDocumentedShape() async throws {
    let findMy = interface()

    do {
      try await findMy.requestShare(handle: Self.handle)
      Issue.record("the request should have failed")
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
      #expect(status == 500)
      #expect(envelope.error?.type == .iMessageError)
      #expect(envelope.error?.message == "Messages said no")
    }
  }

  // MARK: - The gate, which is not a Messages failure

  @Test("A gated friends refresh answers from the cache instead of asking Messages")
  func gatedRefreshDoesNotReachMessages() async throws {
    // The second call lands inside the fifteen-second window — not a timing assumption
    // worth worrying about, since the two calls are microseconds apart, and the gate
    // records only ALLOWED attempts so the first one is what starts the window.
    //
    // The helper still refuses everything. If the gate let this through, the assertion
    // below would see `.messagesFailed` rather than a value, which is precisely the
    // regression it is here to catch.
    let findMy = interface()
    _ = try? await findMy.refreshFriends()

    let second = try await findMy.refreshFriends()

    guard case .tooSoon(_, let retryAfter) = second else {
      Issue.record("a second refresh inside the window must be refused, got \(second)")
      return
    }
    #expect(retryAfter > .zero)
  }

  @Test("A gated location refresh with nothing cached is a 404, not an iMessage error")
  func gatedLocationWithNoCacheIsNotFound() async throws {
    // `refreshLocation` is the one that can still throw on the refused path: with no cached
    // fix there is nothing to answer with. It must stay `.notFound` — the caller's problem
    // is that this person's location is not known yet, not that Messages refused, and a 500
    // would invite a retry that the gate will refuse just as fast.
    let findMy = interface()
    _ = try? await findMy.refreshLocation(handle: Self.handle)

    do {
      _ = try await findMy.refreshLocation(handle: Self.handle)
      Issue.record("a gated refresh with no cache should have thrown")
    } catch let error as InterfaceError {
      guard case .notFound = error else {
        Issue.record("expected .notFound, got \(error)")
        return
      }
    }
  }

  @Test("With no helper, a FindMy operation is unavailable rather than refused")
  func missingHelperIsNotAMessagesFailure() async throws {
    let findMy = interface(privateAPI: nil)

    do {
      try await findMy.requestShare(handle: Self.handle)
      Issue.record("the request should have been refused")
    } catch let error as InterfaceError {
      #expect(error == .helperUnavailable(feature: "requesting a location share"))
    }
  }
}
