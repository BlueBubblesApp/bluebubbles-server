//  UnreachableScriptRunner
//  What a test hands an interface so that nothing it does can reach Messages.
//
//  The real runner really sends: the `swift test` host runs what is posted to the main thread,
//  and Messages accepts the script. A `try?` at the call site hides whatever comes back, so
//  reaching this records an issue as well as throwing.
//
//  A test that means to reach the send path uses a stub of its own that records what it was
//  asked. `RealSenderPolicyTests` keeps the real runner out of the tests.

import BBAppleScript
import Testing

public struct UnreachableScriptRunner: AppleScriptRunning {

  public init() {}

  public func run(
    key: String, source: String, handler: String,
    arguments: [AppleScriptValue], target: String, timeout: Duration
  ) async throws -> String? {
    Issue.record("a test reached the send path with no runner of its own: handler \(handler)")
    throw AppleScriptError.executionFailed(number: 0, message: "this test does not send")
  }
}
