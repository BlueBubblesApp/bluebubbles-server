//  AuditContext
//  Who is acting, carried with the work rather than passed through every signature.
//
//  An audit record has to say who did a thing, and the code that KNOWS is almost never the
//  code that records it: the HTTP dispatcher knows a client's address, the registry knows
//  which service it is starting, the app knows a person clicked, and the settings store that
//  writes the row knows none of that. Threading an actor parameter through every interface,
//  repository and store would put audit plumbing on signatures that have nothing to do with
//  auditing, so the actor rides a task-local instead: set once at the boundary where it is
//  known, read once where the record is written.
//
//  The default when nothing set it is the OPERATOR, and the direction is deliberate. Every
//  other boundary is explicit: a request sets `.client` before the handler runs, the registry
//  sets `.system` around a service's start and stop (and a task a service spawns inherits it),
//  the composition root sets `.system` around assembly. What is left over is code the person
//  at the Mac drove: the app's views and the command line. Defaulting the other way would
//  attribute a person's change to the server, which in an audit log is the worse lie.
//
//  In BBCore because the two ends are in different modules and both are below the audit
//  module: the settings store records a change, the HTTP layer sets the actor, and neither
//  may import the other.

import Foundation

/// Who, or what, caused an auditable action.
public enum AuditActor: Sendable, Hashable {
  /// An API caller, over HTTP or the socket. The address is the one access control resolved,
  /// which can be nil when nothing identified the peer.
  case client(address: String?)
  /// The person at the Mac, through the app's window or the command line.
  case operator
  /// The server itself: a service, startup, the scheduler, a retention sweep. `component`
  /// names which, as a service identifier or a short stable word such as `startup`.
  case system(component: String)

  /// The stored spelling of the kind: `client`, `operator` or `system`.
  public var kind: String {
    switch self {
    case .client: "client"
    case .operator: "operator"
    case .system: "system"
    }
  }

  /// What identifies the actor within its kind: the client's address or the system
  /// component. Nil for the operator, who is one person, and for a client nothing identified.
  public var identifier: String? {
    switch self {
    case .client(let address): address
    case .operator: nil
    case .system(let component): component
    }
  }
}

/// Which way an action reached the server.
///
/// Distinct from the actor: a client is a client over HTTP and over the socket, and the two
/// transports authenticate differently, so an auditor reading a run of failures wants to know
/// which door was being tried.
public enum AuditSource: String, Sendable, Hashable, CaseIterable {
  case http
  case socket
  /// The app's window.
  case app
  /// `bluebubbles-server` on the command line.
  case cli
  /// The server acting on its own.
  case server

  /// The source an actor implies when no boundary said otherwise: a client over HTTP, the
  /// operator through the app, the system from the server. The socket and the command line
  /// set theirs explicitly.
  public static func implied(by actor: AuditActor) -> AuditSource {
    switch actor {
    case .client: .http
    case .operator: .app
    case .system: .server
    }
  }
}

/// Everything known about the cause of the work in flight.
public struct AuditContext: Sendable, Hashable {
  public var actor: AuditActor
  /// Nil means "whatever the actor implies"; see `AuditSource.implied(by:)`.
  public var source: AuditSource?
  /// One identifier per request, so the transport record and every domain record written
  /// while it was handled can be joined afterwards. Nil outside a request.
  public var requestID: String?
  /// The route template the request matched, never the resolved path, which on a chat or
  /// handle route carries somebody's address.
  public var route: String?

  public init(
    actor: AuditActor, source: AuditSource? = nil, requestID: String? = nil, route: String? = nil
  ) {
    self.actor = actor
    self.source = source
    self.requestID = requestID
    self.route = route
  }

  /// The context of the work in flight, or nil when no boundary set one.
  @TaskLocal public static var current: AuditContext?

  /// The actor to record when nothing set one. See the file header for why it is the person.
  public static let fallbackActor = AuditActor.operator

  /// What a record written now should carry: the task-local when there is one, the fallback
  /// otherwise.
  public static var effective: AuditContext {
    current ?? AuditContext(actor: fallbackActor)
  }

  /// Runs `body` with `context` as the actor of everything it does, including the tasks it
  /// spawns with `Task {}`. A `Task.detached` does not inherit it, which is the usual rule.
  public static func with<T>(
    _ context: AuditContext, _ body: () async throws -> T
  ) async rethrows -> T {
    try await $current.withValue(context, operation: body)
  }

  /// `with(_:_:)` for the common case of an actor and nothing else.
  public static func acting<T>(
    as actor: AuditActor, _ body: () async throws -> T
  ) async rethrows -> T {
    try await with(AuditContext(actor: actor), body)
  }
}
