//  HTTPErrors
//  The status <-> error-type pairings, which are part of the client contract.
//
//  Two of these are load-bearing and easy to "fix" into a break:
//    - NotFound reports "Database Error", not "Not Found". Odd, but shipped.
//    - IMessageError returns HTTP 500, and it is the response clients depend on most: a send
//      failure comes back as 500 with the serialized Message in `data`.
//
//  See `.claude/docs/api.md`.

import BBSerialization
import Foundation

public protocol HTTPError: Error, Sendable {
  var status: Int { get }
  var errorType: ErrorType { get }
  var responseMessage: String { get }
  var errorMessage: String { get }
  var data: JSONValue? { get }
}

extension HTTPError {
  public var data: JSONValue? { nil }

  public func envelope() -> ResponseEnvelope {
    ResponseEnvelope(
      status: status,
      message: responseMessage,
      error: ErrorBody(type: errorType, message: errorMessage),
      data: data
    )
  }
}

public struct Unauthorized: HTTPError {
  public let status = 401
  public let errorType = ErrorType.authenticationError
  public let responseMessage = ResponseMessage.unauthorized.rawValue
  public let errorMessage: String
  public init(_ message: String = "Unauthorized") { self.errorMessage = message }
}

public struct Forbidden: HTTPError {
  public let status = 403
  public let errorType = ErrorType.authenticationError
  public let responseMessage = ResponseMessage.forbidden.rawValue
  public let errorMessage: String
  public init(_ message: String = "Forbidden") { self.errorMessage = message }
}

public struct BadRequest: HTTPError {
  public let status = 400
  public let errorType = ErrorType.validationError
  public let responseMessage = ResponseMessage.badRequest.rawValue
  public let errorMessage: String
  public init(_ message: String = "Bad Request") { self.errorMessage = message }
}

/// 404 pairs with "Database Error". Not a typo on our part — it is what ships.
public struct NotFound: HTTPError {
  public let status = 404
  public let errorType = ErrorType.databaseError
  public let responseMessage = ResponseMessage.notFound.rawValue
  public let errorMessage: String
  public init(_ message: String = "Not Found") { self.errorMessage = message }
}

/// 413, for a request body past `maximumBodySize`.
///
/// Paired with `validationError` rather than `serverError`: the size limit is the client's
/// constraint to respect, and a client that retries a 500 forever will stop on a 4xx.
public struct PayloadTooLarge: HTTPError {
  public let status = 413
  public let errorType = ErrorType.validationError
  public let responseMessage = ResponseMessage.badRequest.rawValue
  public let errorMessage: String

  public init(limit: Int) {
    self.errorMessage = "Request body exceeds the \(limit / (1024 * 1024)) MB limit"
  }
}

public struct ServerError: HTTPError {
  public let status = 500
  public let errorType = ErrorType.serverError
  public let responseMessage = ResponseMessage.serverError.rawValue
  public let errorMessage: String
  public init(_ message: String = "Server Error") { self.errorMessage = message }
}

/// HTTP 500 with the serialized Message in `data`.
///
/// This is the shape clients rely on for a failed send, so it must not become a 4xx however
/// much more correct that would be.
public struct IMessageError: HTTPError {
  public let status = 500
  public let errorType = ErrorType.iMessageError
  public let responseMessage = ResponseMessage.unknownIMessageError.rawValue
  public let errorMessage: String
  public let data: JSONValue?

  public init(_ message: String = "Unknown iMessage Error", data: JSONValue? = nil) {
    self.errorMessage = message
    self.data = data
  }

  /// Raised when a route needs the Private API and the helper is not connected. The
  /// message text is what the current middleware emits, verbatim.
  public static func helperUnavailable() -> IMessageError {
    IMessageError(
      "Please make sure you have completed the setup for the Private API, "
        + "and your helper is connected!"
    )
  }
}

/// 503, for a dependency that is configured but not currently usable — chiefly a chat.db
/// this server cannot read.
///
/// Distinct from `ServerError`: 500 says this server is broken, 503 says a thing it needs is
/// not available right now, which is the difference between "report a bug" and "grant Full
/// Disk Access". It lived in `HydrationHandlers.swift` while being thrown from four handler
/// groups, which is the sort of thing nobody finds until they go looking for it here.
public struct ServiceUnavailable: HTTPError {
  public let status = 503
  public let errorType = ErrorType.serverError
  public let responseMessage = ResponseMessage.serverError.rawValue
  public let errorMessage: String
  public init(_ message: String) { self.errorMessage = message }
}

public struct GatewayTimeout: HTTPError {
  public let status = 504
  public let errorType = ErrorType.gatewayTimeout
  public let responseMessage = ResponseMessage.gatewayTimeout.rawValue
  public let errorMessage: String

  public init(_ message: String = "The data in your request took too long to get to the server!") {
    self.errorMessage = message
  }

  /// The timeout body is built by hand rather than by the standard error path, and its
  /// `message` embeds the elapsed milliseconds.
  public static func envelope(afterMilliseconds elapsed: Int) -> ResponseEnvelope {
    ResponseEnvelope(
      status: 504,
      message: "The request timed-out after \(elapsed) ms!",
      error: ErrorBody(
        type: .gatewayTimeout,
        message: "The data in your request took too long to get to the server!"
      )
    )
  }
}

/// Validation failures surface only the FIRST error string, matching validatorjs. Returning
/// all of them would be more useful and would change the response body.
public struct ValidationFailure: HTTPError {
  public let status = 400
  public let errorType = ErrorType.validationError
  public let responseMessage = ResponseMessage.badRequest.rawValue
  public let errorMessage: String

  public init(errors: [String]) {
    self.errorMessage = errors.first ?? "Bad Request"
  }
}
