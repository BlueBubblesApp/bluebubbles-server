//  InterfaceError+HTTP
//  The one place that knows the interfaces layer's failures have an HTTP spelling.
//
//  `InterfaceError` is defined without importing BBHTTPAPI so the layer that throws it stays
//  transport-neutral. This file supplies the translation, and it lives beside the handlers
//  because that is the boundary the translation belongs to: everything above here speaks HTTP,
//  everything below speaks the domain.
//
//  Conforming to `HTTPError` rather than mapping in `ErrorRenderer` is deliberate. The renderer
//  already matches `HTTPError` first and uses its status verbatim, so this reuses the existing
//  path instead of adding a second one — and it keeps the status decision next to the case it
//  belongs to rather than in a switch somewhere else.
//
//  **The pairings are the client contract, not preferences.** Two look wrong and are not:
//  404 reports "Database Error", and a Messages refusal is a 500 rather than a 4xx. Both are
//  what the reference server sends and what clients have branched on for years. See
//  `Sources/BBHTTPAPI/HTTPErrors.swift`.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

extension InterfaceError: HTTPError {

  public var status: Int {
    switch self {
    case .invalidRequest: 400
    case .notFound: 404
    case .unavailable: 503
    // 500, however much more correct a 4xx would be. This is the response clients read for
    // a failed send and the shape they depend on most.
    case .messagesFailed, .helperUnavailable, .capabilityUnavailable: 500
    }
  }

  public var errorType: ErrorType {
    switch self {
    case .invalidRequest: .validationError
    // Not `.notFound` — the reference pairs 404 with "Database Error". Odd, but shipped.
    case .notFound: .databaseError
    case .unavailable: .serverError
    case .messagesFailed, .helperUnavailable, .capabilityUnavailable: .iMessageError
    }
  }

  /// The envelope's sentence — NOT the short `ResponseMessage` value.
  ///
  /// This was the second copy of the swap `HTTPErrors.swift` had, and the worse of the two:
  /// nearly every failure a handler produces arrives as an `InterfaceError`, so this switch
  /// decided the `message` on most of the error responses the server sends. Deferred to the
  /// error types themselves rather than transcribed again here, because a third copy of six
  /// sentences would drift from the other two silently.
  public var responseMessage: String {
    switch self {
    case .invalidRequest: BadRequest().responseMessage
    case .notFound: NotFound().responseMessage
    case .unavailable: ServiceUnavailable("").responseMessage
    // The gate's sentence goes in `message`, not in `error.message`. The reference's
    // `PrivateApiMiddleware` throws `new IMessageError({ message: "Please make sure you
    // have completed the setup…", error: ex.message })` — so the long sentence a client
    // shows a person is the ENVELOPE's, and the detail is which half failed. This server
    // had them the other way round.
    case .helperUnavailable:
      "Please make sure you have completed the setup for the Private API, "
        + "and your helper is connected!"
    // NOT the gate's sentence. This case exists for a capability the reference has no
    // notion of — group creation through a user-installed Shortcut — so there is nothing to
    // match, and its own explanation is the whole reason it is a separate case.
    case .messagesFailed, .capabilityUnavailable: IMessageError().responseMessage
    }
  }

  /// The DETAIL — which half of the gate failed, matching `checkPrivateApiStatus`.
  ///
  /// The reference distinguishes "not enabled" from "not connected" here, and a client
  /// diagnosing a setup problem needs to know which: one is a setting, the other is an
  /// injection that did not take.
  public var errorMessage: String {
    switch self {
    case .helperUnavailable: "iMessage Private API Helper is not connected!"
    default: body
    }
  }

  /// Only `capabilityUnavailable` carries one.
  ///
  /// `helperUnavailable` used to as well, and it was an added key: the reference's Private
  /// API gate sends the envelope and nothing else, and the two-way diff treats a key we add
  /// exactly like one we drop. The feature name survives in the log, which was always the
  /// more useful of the two places.
  ///
  /// `capabilityUnavailable` keeps it because there is nothing to diverge from — the
  /// reference has no Shortcut path, so it never produces this response at all.
  public var data: JSONValue? {
    switch self {
    case .capabilityUnavailable(_, let feature): .object(["feature": .string(feature)])
    default: nil
    }
  }
}
