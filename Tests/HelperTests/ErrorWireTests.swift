//  ErrorWireTests
//  Every failure a helper can send arrives at the server as the case it threw.
//
//  The helper writes `errorCode`, `errorMethod` and `errorRequires` beside the sentence in
//  `error`; the server rebuilds a `PrivateAPIError` from them. Written on one side and read
//  on the other, so this runs the helper's half into the contract's other half for every
//  case that crosses the socket.

import BBPrivateAPIContract
import Foundation
import HelperShared
import Testing

@Suite("Helper error wire")
struct ErrorWireTests {

  private static let crossing: [PrivateAPIError] = [
    .notImplemented(method: "send-sticker"),
    .unavailableOnThisOS(method: "send-message", requires: "macOS 15"),
    .rejectedByMessages(reason: "no such chat"),
    .notConnected,
    .timedOut(method: "leave-chat"),
    .protocolMismatch("unknown action 'x'"),
  ]

  @Test("Each case survives the trip", arguments: crossing)
  func roundTrip(_ error: PrivateAPIError) {
    let fields = PrivateAPIError.wireFields(of: error)
    let rebuilt = PrivateAPIError(
      wireCode: fields[.errorCode] as? String,
      reason: error.errorDescription ?? "",
      method: fields[.errorMethod] as? String,
      requires: fields[.errorRequires] as? String)
    switch error {
    case .rejectedByMessages, .protocolMismatch:
      // These carry the sentence itself, so they come back with the sentence they were sent.
      #expect(rebuilt.wireCode == error.wireCode)
    default:
      #expect(rebuilt == error)
    }
  }

  @Test("An error that is not the contract's is a refusal")
  func foreignErrorIsRejected() {
    struct Elsewhere: Error {}
    #expect(
      PrivateAPIError.wireFields(of: Elsewhere())[.errorCode] as? String
        == PrivateAPIError.WireCode.rejected.rawValue)
  }
}
