//  ContextualService
//  What every built-in service shares: the host it is built from and its registry key.
//
//  There were two more things here — `TaskBox` and `RuntimeBox`, single-purpose actors that
//  held a `Task` and the Private API runtime so a service could keep mutable state without
//  `@unchecked Sendable`. `Service` requires `Actor` now, so a service IS an isolation
//  domain and holds that state as an ordinary `private var`. Both boxes were deleted with
//  their last caller.
//
//  Each service lives in its own file in this directory. What a service adds over the module
//  that does the work is its identity, its dependencies and its restart policy — the three
//  things the registry needs to start everything in the right order and keep it running.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBPrivateAPI
import BBServiceKit
import Foundation

/// The registry's keys, taken from the manifests.
///
/// Derived rather than declared, so a service's manifest identifier and the key the registry
/// files it under cannot drift. Independent short strings — `"http"` — let a dependency
/// written as `ServiceID.http` silently fail to match a service whose manifest calls it
/// something else, and the topological sort then orders on a graph with missing edges.
extension ServiceID {
  public static let permissions = ServiceID(BuiltInManifests.ID.permissions.rawValue)
  public static let contactsIngest = ServiceID(BuiltInManifests.ID.contacts.rawValue)
  public static let changeDetection = ServiceID(BuiltInManifests.ID.changeDetection.rawValue)
  public static let http = ServiceID(BuiltInManifests.ID.http.rawValue)
  public static let socket = ServiceID(BuiltInManifests.ID.socket.rawValue)
  public static let privateAPI = ServiceID(BuiltInManifests.ID.privateAPI.rawValue)
  public static let push = ServiceID(BuiltInManifests.ID.push.rawValue)
  public static let webhooks = ServiceID(BuiltInManifests.ID.webhooks.rawValue)
  public static let sleepPrevention = ServiceID(BuiltInManifests.ID.sleepPrevention.rawValue)
  public static let scheduledMessages = ServiceID(BuiltInManifests.ID.scheduledMessages.rawValue)
  public static let launchAtLogin = ServiceID(BuiltInManifests.ID.launchAtLogin.rawValue)
}

/// Shared plumbing: every service here is built from the same context.
public protocol ContextualService: Service where Host == AppContext {
  var context: AppContext { get }
}

extension ContextualService {
  /// This service's settings, narrowed to what its manifest declares.
  ///
  /// Reading a core setting through here fails unless the manifest asked for it, which is
  /// what turns the entitlement list from a description into a control. Its own namespace
  /// needs no entitlement — `scoped.own("auth_token")` is always permitted, and cannot
  /// reach another service's field.
  public var scoped: ScopedSettings {
    context.scopedSettings(for: Self.manifest)
  }
}

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
