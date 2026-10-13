//  RequestAuditRecord
//  What one finished request looked like from the outside, handed to the audit log.

import Foundation

/// What one finished request looked like from the outside, for the audit log.
///
/// Built by `dispatch` on the way out, success or failure, so a refused request is recorded
/// with its 401 beside the ones that succeeded. No body, no query, no resolved path: the
/// route template is the one spelling that cannot carry a person's address.
public struct RequestAuditRecord: Sendable, Equatable {
  public let requestID: String
  public let method: HTTPMethod
  public let routeTemplate: String
  public let handlerID: HandlerID
  public let status: Int
  public let duration: Duration
  /// The identity access control resolved, or the peer when it resolved nothing.
  public let clientAddress: String?
  /// Whether a credential was accepted. False for a refused request and for the two routes
  /// that need none.
  public let isAuthenticated: Bool

  public init(
    requestID: String, method: HTTPMethod, routeTemplate: String, handlerID: HandlerID,
    status: Int, duration: Duration, clientAddress: String?, isAuthenticated: Bool
  ) {
    self.requestID = requestID
    self.method = method
    self.routeTemplate = routeTemplate
    self.handlerID = handlerID
    self.status = status
    self.duration = duration
    self.clientAddress = clientAddress
    self.isAuthenticated = isAuthenticated
  }
}
