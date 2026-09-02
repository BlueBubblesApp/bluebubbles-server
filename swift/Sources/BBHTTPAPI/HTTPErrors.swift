//  HTTPErrors
//  The error envelope, which is part of the client contract in all three of its fields.
//
//  **`message` is a sentence; `error.message` is the detail.** Not the other way round, and
//  that is what this file used to have. Every error here set `message` to the short
//  `ResponseMessage` value — "Not Found", "Bad Request" — where the reference sends
//  "The requested resource was not found" and puts the short value in `error.message` as the
//  DEFAULT detail. So every error response on every v1 route carried the wrong text in the
//  one field a client is most likely to show a person. Found by replaying the recorded
//  corpus (`FixtureReplayTests`), which is the first thing that ever read it back.
//
//  The reference is `packages/server/src/server/api/http/api/v1/responses/errors.ts`. Its
//  constructors take `{ message, error }` — a sentence and a detail — and the initialisers
//  below take the same two in the same order of importance, with `message:` spelled the same
//  way so the two can be read side by side.
//
//  Two more are load-bearing and easy to "fix" into a break:
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
  public let responseMessage: String
  public let errorMessage: String

  public init(
    _ detail: String = ResponseMessage.unauthorized.rawValue,
    message: String = "You are not authorized to access this resource"
  ) {
    self.errorMessage = detail
    self.responseMessage = message
  }
}

public struct Forbidden: HTTPError {
  public let status = 403
  public let errorType = ErrorType.authenticationError
  public let responseMessage: String
  public let errorMessage: String

  public init(
    _ detail: String = ResponseMessage.forbidden.rawValue,
    message: String = "You are forbidden from accessing this resource"
  ) {
    self.errorMessage = detail
    self.responseMessage = message
  }
}

public struct BadRequest: HTTPError {
  public let status = 400
  public let errorType = ErrorType.validationError
  public let responseMessage: String
  public let errorMessage: String

  public init(
    _ detail: String = ResponseMessage.badRequest.rawValue,
    message: String = "You've made a bad request! Please check your request params & body"
  ) {
    self.errorMessage = detail
    self.responseMessage = message
  }
}

/// 404 pairs with "Database Error". Not a typo on our part — it is what ships.
public struct NotFound: HTTPError {
  public let status = 404
  public let errorType = ErrorType.databaseError
  public let responseMessage: String
  public let errorMessage: String

  public init(
    _ detail: String = ResponseMessage.notFound.rawValue,
    message: String = "The requested resource was not found"
  ) {
    self.errorMessage = detail
    self.responseMessage = message
  }
}

/// 413, for a request body past `maximumBodySize`.
///
/// Paired with `validationError` rather than `serverError`: the size limit is the client's
/// constraint to respect, and a client that retries a 500 forever will stop on a 4xx.
public struct PayloadTooLarge: HTTPError {
  public let status = 413
  public let errorType = ErrorType.validationError
  public let responseMessage = "You've made a bad request! Please check your request params & body"
  public let errorMessage: String

  public init(limit: Int) {
    self.errorMessage = "Request body exceeds the \(limit / (1024 * 1024)) MB limit"
  }
}

public struct ServerError: HTTPError {
  public let status = 500
  public let errorType = ErrorType.serverError
  public let responseMessage: String
  public let errorMessage: String

  public init(
    _ detail: String = ResponseMessage.serverError.rawValue,
    message: String = "The server has encountered an error"
  ) {
    self.errorMessage = detail
    self.responseMessage = message
  }

  /// The envelope for something nobody typed a status for.
  ///
  /// Its own constructor because the reference has one: an exception that reaches the error
  /// middleware without being an `HTTPError` does NOT get `ServerError`'s sentence, it gets
  /// "An unhandled error has occurred!" — which is how a client tells "this route decided to
  /// fail" from "this server fell over". Losing that distinction is losing a diagnostic.
  public static func unhandled(_ detail: String) -> ServerError {
    ServerError(detail, message: "An unhandled error has occurred!")
  }
}

/// HTTP 500 with the serialized Message in `data`.
///
/// This is the shape clients rely on for a failed send, so it must not become a 4xx however
/// much more correct that would be.
public struct IMessageError: HTTPError {
  public let status = 500
  public let errorType = ErrorType.iMessageError
  public let responseMessage: String
  public let errorMessage: String
  public let data: JSONValue?

  public init(
    _ detail: String = ResponseMessage.unknownIMessageError.rawValue,
    message: String = "iMessage has encountered an error",
    data: JSONValue? = nil
  ) {
    self.errorMessage = detail
    self.responseMessage = message
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
  public let responseMessage: String
  public let errorMessage: String

  public init(_ detail: String, message: String = "The server has encountered an error") {
    self.errorMessage = detail
    self.responseMessage = message
  }
}

public struct GatewayTimeout: HTTPError {
  public let status = 504
  public let errorType = ErrorType.gatewayTimeout
  public let responseMessage: String
  public let errorMessage: String

  public init(
    _ detail: String = "The data in your request took too long to get to the server!",
    message: String = "The server took too long to response!"
  ) {
    self.errorMessage = detail
    self.responseMessage = message
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
  public let responseMessage = "You've made a bad request! Please check your request params & body"
  public let errorMessage: String

  public init(errors: [String]) {
    self.errorMessage = errors.first ?? "Bad Request"
  }
}
