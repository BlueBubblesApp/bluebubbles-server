//  EnrollmentError+HTTP
//  The token-auth layer's failures have an HTTP spelling too.
//
//  `EnrollmentError` is thrown by `BBAuth`, which does not import the transport, so the
//  status for each case lives here, beside the handlers, as `InterfaceError`'s does. Without
//  it every case reached the renderer as an unrecognised error and was answered 500: a
//  revoke naming a device that was never enrolled read as the server failing.
//
//  The auth routes are additive (v2, `RouteTable.auth`), so there is no reference response to
//  match; these pairings are ours. The handlers still catch the credential cases themselves
//  where they need to (`AuthHandlers.token` records the failure and answers one sentence for
//  every rejection, so a caller cannot tell an unknown client from a wrong secret); this is
//  what everything else falls back to.

import BBAuth
import BBHTTPAPI
import BBSerialization
import Foundation

extension EnrollmentError: HTTPError {

  public var status: Int {
    switch self {
    // The caller's credential was refused.
    case .invalidEnrollmentCode, .enrollmentCodeExpired, .invalidClientCredentials,
      .deviceRevoked:
      401
    // A device id that names nothing, as `NotFound` answers a missing record.
    case .unknownDevice: 404
    // The routes are only mounted when token auth is on, so reaching one without the
    // registry behind it is the server's own wiring failing, not the caller's mistake. 503
    // rather than 403: nothing the caller does or is refused explains it.
    case .notEnabled: 503
    }
  }

  public var errorType: ErrorType {
    switch self {
    case .invalidEnrollmentCode, .enrollmentCodeExpired, .invalidClientCredentials,
      .deviceRevoked:
      .authenticationError
    // Paired as `NotFound` pairs it, so a missing record is one shape on the wire.
    case .unknownDevice: .databaseError
    case .notEnabled: .serverError
    }
  }

  /// The envelope's sentence, taken from the HTTP type each status already has.
  public var responseMessage: String {
    switch self {
    case .invalidEnrollmentCode, .enrollmentCodeExpired, .invalidClientCredentials,
      .deviceRevoked:
      Unauthorized().responseMessage
    case .unknownDevice: NotFound().responseMessage
    case .notEnabled: ServiceUnavailable("").responseMessage
    }
  }

  public var errorMessage: String { body }
}
