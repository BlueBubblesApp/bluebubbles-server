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

  public var responseMessage: String {
    switch self {
    case .invalidRequest: ResponseMessage.badRequest.rawValue
    case .notFound: ResponseMessage.notFound.rawValue
    case .unavailable: ResponseMessage.serverError.rawValue
    case .messagesFailed, .helperUnavailable, .capabilityUnavailable:
      ResponseMessage.unknownIMessageError.rawValue
    }
  }

  public var errorMessage: String {
    switch self {
    // The canonical text, verbatim. Clients display it and some match on it, so the feature
    // name goes in `data` below rather than into this string.
    case .helperUnavailable: IMessageError.helperUnavailable().errorMessage
    default: body
    }
  }

  public var data: JSONValue? {
    switch self {
    case .helperUnavailable(let feature), .capabilityUnavailable(_, let feature):
      .object(["feature": .string(feature)])
    default: nil
    }
  }
}
