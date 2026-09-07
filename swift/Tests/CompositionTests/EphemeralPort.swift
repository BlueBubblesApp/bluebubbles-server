//  EphemeralPort
//  Binding a listener in a test without guessing a port.
//
//  Eight suites here start a real listener, and none of them may pick
//  `Int.random(in: 20_000..<60_000)` and hope. That is a birthday problem against every other
//  test in the run and against whatever else the machine is doing, and it produces exactly
//  the failure it looks like it would: `SignalOwnershipTests` and `PeerAddressTests` failing
//  intermittently with "Port N is already in use", roughly once in a few hundred runs — often
//  enough to be seen, rarely enough to be re-run and ignored.
//
//  Three suites had grown a retry loop around the guess, which lowers the odds without
//  removing them and turns a collision into seconds of latency.
//
//  **Port 0 removes the problem instead of making it rarer.** It asks the kernel for a free
//  port, and the kernel does not hand out one it has already given away. `HTTPListener.port`
//  reports what was actually assigned — that is what it is for — so the test can connect to
//  it. There is nothing left to collide and nothing to retry.

import Foundation

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

extension HTTPListener {

  /// The port this listener is actually on, or a clear failure.
  ///
  /// `port` is optional because a listener that has not started has no port. Inside a test
  /// that has just started one, nil means the start silently did not take — worth failing on
  /// with a sentence rather than unwrapping into a crash with none.
  func boundPortOrFail() throws -> Int {
    guard let port else {
      struct ListenerNotBound: Error, CustomStringConvertible {
        var description: String {
          "the listener reported no port after starting; it did not actually bind"
        }
      }
      throw ListenerNotBound()
    }
    return port
  }
}
