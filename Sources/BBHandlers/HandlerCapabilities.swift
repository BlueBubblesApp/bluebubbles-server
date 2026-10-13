//  HandlerCapabilities
//  The capabilities only a handler composes.
//
//  `BBInterfaces/Capabilities.swift` holds the protocols three consumers share: the
//  handlers, the composition root and the SwiftUI app. These two are composed by handlers
//  alone: the security routes and the token-auth routes. Keeping them there made the domain
//  layer import the auth module to name protocols nothing in it used, so they live here,
//  next to their only composers. The container still conforms in the composition root.
//
//  `UpdateInstalling` used to be here too, until the app conformed to it: a protocol the
//  app implements and a handler consumes is exactly what `Capabilities.swift` is for.

import BBAuth
import Foundation

public protocol AccessControlProviding: Sendable {
  var accessControl: AccessControlService { get }
}

public protocol TokenAuthProviding: Sendable {
  var tokenAuth: TokenAuthService { get }
}
