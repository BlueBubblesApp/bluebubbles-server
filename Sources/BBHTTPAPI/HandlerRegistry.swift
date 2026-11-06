//  HandlerRegistry
//  Which controller answers which route, and the error a mismatch raises at mount time.

import BBCore
import Foundation

/// Maps `HandlerID` to an implementation.
///
/// A route with no registered handler is a hard failure at mount time, not a 404 at runtime.
/// That is how the route table stays honest: adding a route to the table without writing its
/// controller refuses to start rather than quietly serving a 404 that looks like a client
/// bug.
public struct HandlerRegistry: Sendable {

  private var handlers: [HandlerID: RouteHandler] = [:]

  public init() {}

  public mutating func register(_ id: HandlerID, _ handler: @escaping RouteHandler) {
    handlers[id] = handler
  }

  public func handler(for id: HandlerID) -> RouteHandler? { handlers[id] }

  /// Handler IDs the table references that nothing has registered.
  public func missing(for groups: [RouteGroup]) -> [HandlerID] {
    var seen = Set<HandlerID>()
    for group in groups {
      for route in group.routes where handlers[route.handlerID] == nil {
        seen.insert(route.handlerID)
      }
    }
    return seen.sorted { $0.rawValue < $1.rawValue }
  }
}

public enum HTTPMountError: BBError, CustomStringConvertible {
  case unregisteredHandlers([HandlerID])
  case unrecognizedMethod(method: String, path: String)

  public var description: String {
    switch self {
    case .unregisteredHandlers(let ids):
      "No handler registered for: \(ids.map(\.rawValue).joined(separator: ", "))"
    case .unrecognizedMethod(let method, let path):
      "Route \(path) declares HTTP method '\(method)', which is not a valid method"
    }
  }
}

extension HTTPMountError {
  public var code: String {
    switch self {
    case .unregisteredHandlers: "http.unregistered_handlers"
    case .unrecognizedMethod: "http.unrecognized_method"
    }
  }

  public var domain: String { "HTTP" }

  /// A programming error caught at mount time. It stops the server starting, which is the
  /// point: a route in the contract with no controller behind it reads to a client as a
  /// client bug.
  public var severity: Severity { .critical }

  public var title: String { "The route table and the controllers disagree" }

  public var body: String { description }
}
