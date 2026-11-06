//  RouteModel
//  The types a route is declared with: `HTTPMethod`, `RouteRequirements`, `RouteGate`,
//  `RouteDefinition`, `RouteGroup` and `HandlerID`.
//
//  Its own file so a reader of the vocabulary is not handed the table, and a reader of the
//  table (`RouteTable.swift`) opens the declarations and not what they are made of. Nothing
//  here names a route; every definition is in the table.

import BBAuth
import BBLicense
import Foundation

public enum HTTPMethod: String, Sendable, CaseIterable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case delete = "DELETE"
}

/// Extra middleware a route needs beyond its group's chain.
public struct RouteRequirements: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Requires the Private API helper to be connected. Fails with `IMessageError` (HTTP
  /// 500) and the helper-unavailable message; not a 503, which would be more correct.
  public static let privateAPI = RouteRequirements(rawValue: 1 << 0)

  /// Skips authentication. Only the UI index route.
  public static let unauthenticated = RouteRequirements(rawValue: 1 << 1)

  /// Authenticates IF a credential is offered, and proceeds either way.
  ///
  /// Exists for enrollment, which is reachable by an unenrolled caller by necessity and
  /// accepts either the server password or a one-time code. Marking it `.unauthenticated`
  /// made the password half unreachable: the router only populates `principal` when it
  /// authenticates, so `auth.register` (which decides between the two paths by asking
  /// whether a principal exists) saw nil every time and demanded a code. Nothing issues
  /// codes (`issueEnrollmentCode` has no route and no UI), so the whole token-auth surface
  /// was unreachable: no credentials could be minted, and `token`, `rotate` and `revoke`
  /// all need them.
  ///
  /// A failed credential is NOT an error here. Someone enrolling with a code has no
  /// password to send, and rejecting them for that would close the other door.
  public static let optionalAuthentication = RouteRequirements(rawValue: 1 << 2)
}

/// A switch a route sits behind: something the operator turns on, or something this Mac
/// has to be able to do.
///
/// Declared in the table and checked by `RouteGateStage`, after the Private API stage and
/// before the body is read, so a route behind a switch says so where every other
/// precondition of the route is said, and no handler carries a copy of the check: with a copy
/// per handler, the route that forgot its copy is open, and nothing says so.
///
/// **A NAME, not a setting.** This module does not know `BBSettings`, by design; what a gate
/// MEANS is decided by whoever composes the router (`RouteGates` in `BBHandlers`), through an
/// exhaustive switch, so a new case does not compile until something evaluates it.
public enum RouteGate: String, Sendable, CaseIterable {
  /// The FaceTime Private API switch, which every FaceTime route but `restart` and
  /// `availability/facetime` sits behind.
  case faceTime
  /// The narrower switch on dialling out (`POST facetime/call`).
  case faceTimeOutgoingCalls
  /// The incoming-call hand-off switch.
  case faceTimeIncomingHandoff
  /// The flag on sharing this Mac's location through FindMy.
  case findMyLocationSharing
  /// Whether this Mac can use Apple's Send Later at all.
  case sendLater
}

public struct RouteDefinition: Sendable {
  public let method: HTTPMethod
  /// Path relative to the group prefix, such as `:guid/download`.
  public let path: String
  public let handlerID: HandlerID
  public let requirements: RouteRequirements
  /// The switches this route sits behind, checked in this order after its group's.
  public let gates: [RouteGate]
  /// Declared per route so scope enforcement is metadata rather than a second middleware
  /// pass. Unused while `auth_mode` is `password`, where the principal holds every scope.
  public let scope: Scope
  /// The subscription tier this route needs, or `nil` for free surface.
  ///
  /// A VALUE rather than a bit in `RouteRequirements`, because an OptionSet cannot carry one
  /// and a bit per tier would collapse the ordering the tier model exists to express. Combines
  /// with the group's floor by taking the HIGHER of the two, so a group-level floor cannot be
  /// lowered by a route.
  ///
  /// **Never set on a v1 route.** `RouteTableTests` enforces that: gating something a shipped
  /// client already calls is a compatibility break, whatever the license says.
  public let minimumTier: SubscriptionTier?
  public let requestTimeout: Duration?
  public let responseTimeout: Duration?

  init(
    _ method: HTTPMethod,
    _ path: String,
    _ handlerID: HandlerID,
    scope: Scope = .messagesRead,
    requires requirements: RouteRequirements = [],
    requiring gates: [RouteGate] = [],
    minimumTier: SubscriptionTier? = nil,
    requestTimeout: Duration? = nil,
    responseTimeout: Duration? = nil
  ) {
    self.method = method
    self.path = path
    self.handlerID = handlerID
    self.requirements = requirements
    self.gates = gates
    self.scope = scope
    self.minimumTier = minimumTier
    self.requestTimeout = requestTimeout
    self.responseTimeout = responseTimeout
  }
}

public struct RouteGroup: Sendable {
  public let name: String
  /// Empty for the General group, whose routes sit directly under `/api/v1`.
  public let prefix: String
  public let requirements: RouteRequirements
  /// Switches every route in the group sits behind, checked before each route's own. A whole
  /// capability is gated by one edit here and cannot be half-gated by omission.
  public let gates: [RouteGate]
  public let responseTimeout: Duration?
  /// Mounts at the server root instead of under `/api/v<n>`.
  ///
  /// True for exactly one group: the landing page, which is Node's separate
  /// `HttpRoutes.ui` definition rather than part of the versioned API. Keeping it a flag on
  /// the group rather than a special case in `buildRouter` means the path a request will
  /// actually hit is still derivable from the table alone, which is what
  /// `mountedRoutes()` and the parity extractor both depend on.
  public let mountsAtRoot: Bool
  /// Which API version this group mounts under.
  ///
  /// **v1 is the Node server's surface and nothing else.** Every route in it exists because
  /// the Electron server had it, which is what lets the parity harness diff the two tables
  /// as equals and what lets a client upgrade without noticing. A bug FIX belongs in v1: if
  /// this server answers a v1 route differently from the reference, one of them is wrong.
  /// New capability does not, however small and however additive it looks.
  ///
  /// **v2 is everything this server does that the Node server never did.** Its routes are
  /// still individually gated: by a feature flag, by `auth_mode`, by `#if DEBUG`,
  /// so the version is not a switch that turns them all on. It is where a client goes
  /// looking for what is new, and it keeps that question separable from "is this server
  /// still compatible".
  public let apiVersion: Int
  /// A floor for every route in the group. Declared here rather than repeated per route so a
  /// whole capability is gated by one edit and cannot be half-gated by omission.
  public let minimumTier: SubscriptionTier?
  public let routes: [RouteDefinition]

  init(
    _ name: String,
    prefix: String = "",
    requires requirements: RouteRequirements = [],
    requiring gates: [RouteGate] = [],
    responseTimeout: Duration? = nil,
    mountsAtRoot: Bool = false,
    apiVersion: Int = 1,
    minimumTier: SubscriptionTier? = nil,
    routes: [RouteDefinition]
  ) {
    self.name = name
    self.prefix = prefix
    self.requirements = requirements
    self.gates = gates
    self.responseTimeout = responseTimeout
    self.mountsAtRoot = mountsAtRoot
    self.apiVersion = apiVersion
    self.minimumTier = minimumTier
    self.routes = routes
  }

  /// The switches a request to `route` must find on: the group's, then the route's, each once.
  public func gates(for route: RouteDefinition) -> [RouteGate] {
    var seen = Set<RouteGate>()
    return (gates + route.gates).filter { seen.insert($0).inserted }
  }

  /// The floor a request to `route` in this group must clear: the higher of the two.
  public func tierFloor(for route: RouteDefinition) -> SubscriptionTier? {
    switch (minimumTier, route.minimumTier) {
    case (nil, nil): nil
    case (let group?, nil): group
    case (nil, let route?): route
    case (let group?, let route?): max(group, route)
    }
  }
}

/// Identifies a handler without importing the controllers here, which keeps the table a
/// pure description that a test can read without standing up the server.
///
/// Deliberately NOT `ExpressibleByStringLiteral`. Every identifier is declared once in
/// `HandlerIDs.swift`, so the table and the controller that serves it reference the same
/// constant and a typo is a compile error rather than a route with no handler. The
/// initialiser stays public because the raw form is still needed to read one back: from a
/// recorded fixture, or from the parity harness, but writing a new identifier means adding
/// it there.
public struct HandlerID: Hashable, Sendable {
  public let rawValue: String
  public init(_ value: String) { self.rawValue = value }
}
