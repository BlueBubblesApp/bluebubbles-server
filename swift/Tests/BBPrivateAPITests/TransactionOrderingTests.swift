//  TransactionOrderingTests
//  A reply cannot arrive before there is somewhere to put it.
//
//  `TransactionStore.resolve` drops a reply it has no continuation for, which is correct —
//  an unmatched transaction id is either a duplicate answer or a stale one, and resuming
//  nothing is the only thing it can do. What made that a bug was the ORDER: the request used
//  to be written to the socket before the continuation was registered, so a helper that
//  answered quickly enough resolved a transaction nobody had recorded yet. The reply was
//  discarded and the caller waited out its whole timeout for an answer it had already been
//  sent.
//
//  It surfaced first in the tests that assert on a REJECTION, and that is not a coincidence:
//  an action the helper does not recognise is refused without doing any work, so its reply is
//  the fastest one the protocol can produce and the likeliest to win the race.
//
//  The send now happens inside `await(id:action:timeout:send:)`, after registration. These
//  tests pin that by answering at the earliest moment that exists — from inside `send`
//  itself, which is strictly earlier than any real helper could manage.

import BBPrivateAPIContract
import Foundation
import Logging
import Testing

@testable import BBPrivateAPI

@Suite("Transaction ordering")
struct TransactionOrderingTests {

  private func makeStore() -> TransactionStore {
    TransactionStore(logger: Logger(label: "test.transactions"))
  }

  @Test("A reply that lands during the send is still delivered")
  func replyDuringSendIsDelivered() async throws {
    // Resolving from inside `send` is the worst case made deterministic. If registration
    // did not already happen, this resolve finds nothing, is dropped, and the call below
    // times out instead of returning.
    let store = makeStore()
    let id = "transaction-1"

    let value = try await store.await(
      id: id, action: "ping", timeout: .seconds(2)
    ) {
      await store.resolve(id: id, with: .string("pong"))
    }

    #expect(value?.stringValue == "pong")
  }

  @Test("A rejection that lands during the send is still delivered")
  func rejectionDuringSendIsDelivered() async throws {
    // The same race on the failure path, which is the one that actually broke: an unknown
    // action is refused immediately, so its reply is the fastest the helper ever sends.
    let store = makeStore()
    let id = "transaction-2"

    await #expect(throws: PrivateAPIError.rejectedByMessages(reason: "unknown action")) {
      try await store.await(id: id, action: "no-such-action", timeout: .seconds(2)) {
        await store.fail(
          id: id,
          with: PrivateAPIError.rejectedByMessages(reason: "unknown action")
        )
      }
    }
  }

  @Test("A send that fails does not leave the caller waiting for the timeout")
  func failedSendFailsTheTransaction() async throws {
    // The frame never left, so there is nothing to wait for. Reporting the write's own
    // error immediately beats reporting a timeout thirty seconds later.
    struct WriteFailure: Error {}
    let store = makeStore()

    await #expect(throws: WriteFailure.self) {
      try await store.await(id: "transaction-3", action: "send-message", timeout: .seconds(30)) {
        throw WriteFailure()
      }
    }
  }

  @Test("A timeout names the action, not the transaction id")
  func timeoutNamesTheAction() async throws {
    // `timedOut(method: "3416CCD4-…")` identifies the attempt rather than the operation:
    // unsearchable, and meaningless in a bug report.
    let store = makeStore()

    do {
      _ = try await store.await(
        id: UUID().uuidString, action: "send-message", timeout: .milliseconds(50)
      ) {}
      Issue.record("expected a timeout")
    } catch let error as PrivateAPIError {
      #expect(error == .timedOut(method: "send-message"))
    }
  }
}
