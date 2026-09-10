//  ServiceStartupError
//  What a service throws when it cannot start for a reason it can explain.
//
//  A `BBError` rather than a bare enum, so the sentence a person reads comes from `body`
//  and never from `String(describing:)` printing the case at them.

import BBCore

public enum ServiceStartupError: BBError, CustomStringConvertible {
  case unavailable(String)

  public var description: String {
    switch self {
    case .unavailable(let reason): reason
    }
  }
}

extension ServiceStartupError {
  public var code: String { "service.unavailable" }
  public var domain: String { "Services" }
  public var title: String { "A service could not start" }
  public var body: String { description }
}
