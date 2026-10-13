//  PrivateAPIErrorWireText
//  The sentence a helper sends back for a failure, for either helper.
//
//  The server's `failureReason` treats an empty string as SUCCESS, so this must never return
//  one; an unhelpful message beats a failure that silently reads as a success. Both
//  dispatchers carried this switch with only the app's name different, and that invariant
//  is exactly the kind of thing that should exist once.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIError {

  /// Error text for the wire. `app` is the application this helper is injected into
  /// ("Messages" or "FaceTime") and is all that differs between the two helpers' sentences.
  public static func wireDescription(of error: any Error, app: String) -> String {
    switch error {
    case PrivateAPIError.notImplemented(let method):
      "not implemented in the \(app) helper: \(method)"
    case PrivateAPIError.unavailableOnThisOS(let method, let requires):
      "\(method) is unavailable on this macOS version (requires \(requires))"
    case PrivateAPIError.rejectedByMessages(let reason):
      reason.isEmpty ? "rejected by \(app)" : reason
    case PrivateAPIError.notConnected:
      "the \(app) helper is not connected"
    case PrivateAPIError.timedOut(let method):
      "\(method) timed out"
    // The bare reason: the server rebuilds the case from `errorCode`, and the case's own
    // sentence says what kind of failure it is.
    case PrivateAPIError.protocolMismatch(let reason):
      reason
    default:
      String(describing: error)
    }
  }

  /// The fields beside the sentence that let the server rebuild the case: `errorCode`
  /// always, `errorMethod` and `errorRequires` where the case carries them. An error that is
  /// not a `PrivateAPIError` by the time it reaches the socket is a refusal.
  public static func wireFields(of error: any Error) -> WireObject {
    guard let error = error as? PrivateAPIError else {
      return [.errorCode: WireCode.rejected.rawValue]
    }
    return [
      .errorCode: error.wireCode.rawValue,
      .errorMethod: error.wireMethod,
      .errorRequires: error.wireRequirement,
    ]
  }
}
