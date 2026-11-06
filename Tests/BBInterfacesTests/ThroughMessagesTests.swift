//  ThroughMessagesTests
//  What `throughMessages` turns a backend's failure into.
//
//  Three outcomes, and the first two were one before: a refusal that may pass next time is
//  `messagesFailed`; something this Mac's Messages does not have at all (a missing selector,
//  an unported method, a helper from another build) is `messagesUnsupported`; and a caller
//  that went away is a cancellation, passed through rather than reported as Messages saying
//  no. All three that reach a client are the same 500 `iMessage Error`.

import BBPrivateAPIContract
import Foundation
import Logging
import Testing

@testable import BBInterfaces

private struct Probe: MessagesBackedInterface {
  typealias Helper = Never
  var privateAPI: Never? { nil }
  let logger = Logger(label: "test.through-messages")
}

@Suite("Through Messages")
struct ThroughMessagesTests {

  @Test("A refusal is messagesFailed")
  func refusal() async {
    await #expect(throws: InterfaceError.messagesFailed("no such chat")) {
      try await Probe().throughMessages {
        throw PrivateAPIError.rejectedByMessages(reason: "no such chat")
      }
    }
  }

  @Test("Something this Mac does not have is messagesUnsupported, and answers the same")
  func unsupported() async {
    let missing = PrivateAPIError.unavailableOnThisOS(method: "leave-chat", requires: "x")
    await #expect(throws: InterfaceError.messagesUnsupported(missing.errorDescription ?? "")) {
      try await Probe().throughMessages { throw missing }
    }
  }

  @Test("A cancellation passes through")
  func cancellation() async {
    await #expect(throws: CancellationError.self) {
      try await Probe().throughMessages { throw CancellationError() }
    }
  }
}
