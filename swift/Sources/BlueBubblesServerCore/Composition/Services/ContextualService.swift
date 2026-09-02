//  ContextualService
//  What every built-in service shares: the host it is built from, its registry key, and the
//  two small actors that hold a task or a runtime across `start`, `stop` and `health`.
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

/// Holds the Private API runtime across `start`, `stop` and `health`.
///
/// An actor rather than a bare `var` behind `@unchecked Sendable`. The registry does
/// serialise lifecycle calls today, so the race was not reachable — but that is an
/// invariant of the CALLER, nothing in this type said so, and the annotation that would
/// have flagged it was the one suppressing the check. Removing the annotation is what
/// surfaced it.
actor RuntimeBox {
  private var runtime: PrivateAPIRuntime?
  func set(_ runtime: PrivateAPIRuntime?) { self.runtime = runtime }
  var current: PrivateAPIRuntime? { runtime }
}

actor TaskBox {
  private var task: Task<Void, Never>?
  func set(_ task: Task<Void, Never>) { self.task = task }
  func cancel() {
    task?.cancel()
    task = nil
  }
  var isRunning: Bool { task != nil }
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
