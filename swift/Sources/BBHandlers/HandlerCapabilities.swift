//  HandlerCapabilities
//  The capabilities only a handler composes.
//
//  `BBInterfaces/Capabilities.swift` holds the protocols three consumers share — the
//  handlers, the composition root and the SwiftUI app. These three are composed by handlers
//  alone: the security routes, the token-auth routes and the update endpoint. Keeping them
//  there made the domain layer import the auth and update modules to name protocols nothing
//  in it used, so they live here, next to their only composers. The container still conforms
//  in the composition root, which imports both.

import BBAuth
import BBUpdates
import Foundation

public protocol AccessControlProviding: Sendable {
  var accessControl: AccessControlService { get }
}

public protocol TokenAuthProviding: Sendable {
  var tokenAuth: TokenAuthService { get }
}

/// How the hosting application performs an update.
///
/// Implemented by the SwiftUI app, which owns the updater. The seam exists so the endpoint
/// and the menu item are written once against a capability rather than against a specific
/// host.
public protocol UpdateInstalling: Sendable {
  func beginUpdate(to item: AppcastItem) async
}

public protocol UpdateInstallerProviding: Sendable {
  var updateInstaller: (any UpdateInstalling)? { get async }
}
