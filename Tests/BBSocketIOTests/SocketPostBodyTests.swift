//  SocketPostBodyTests
//  What a polling POST whose body could not be read is answered with.
//
//  A `try?` answered 413 for EVERY body failure, so a body that broke on the way in was
//  reported as too large, which a client acts on by shrinking a packet that was never the
//  problem. The 413 itself is covered over the wire in `SocketEndToEndTests`; the other
//  failures are not reachable that way, because NIO's parser refuses malformed chunking before
//  the handler runs and a client that dropped never reads the answer.

import NIOCore
import Testing

@testable import BBSocketIO

@Suite("Socket POST body failures")
struct SocketPostBodyTests {

  @Test("Only the size limit is a 413; any other body failure is a 400")
  func onlyTheLimitIsTooLarge() {
    #expect(
      SocketIOTransport.status(forBodyFailure: NIOTooManyBytesError(maxBytes: 1))
        == .contentTooLarge)
    #expect(SocketIOTransport.status(forBodyFailure: CancellationError()) == .badRequest)
  }
}
