//  ContextualService
//  What every built-in service shares: the host it is built from and its scoped settings.
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

import BBBuiltIns
import BBCore
import BBPrivateAPI
import BBServiceKit
import Foundation

// There is deliberately no second list of service identifiers here. `BuiltInManifests.ID` is
// the one declaration, and the registry keys on `ServiceIdentifier` directly, so a dependency
// written as `BuiltInManifests.ID.http` is the same value the manifest declares.

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
