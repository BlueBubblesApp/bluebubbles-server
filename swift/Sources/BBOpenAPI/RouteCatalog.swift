//  RouteCatalog
//  Every route this server can serve, in one list, with what it takes to reach each one.
//
//  `RouteTable.groups` is the v1 surface and nothing else; everything additive lives in
//  `AdditiveRoutes` as separate properties that `ServerComposition.additiveGroups` turns on
//  individually. A generated document has to describe BOTH, and has to say which switch each
//  group is behind — "this endpoint exists" and "this endpoint exists if you turned on
//  `additive_endpoints`" are different claims, and a client that cannot tell them apart will
//  report a correctly-configured server as broken.
//
//  This catalog is therefore a second place that lists the additive groups, and that is a
//  real cost: add a group to `additiveGroups` and forget it here, and it silently goes
//  undocumented. `CatalogCompletenessTests` is what stops that — it asserts every public
//  `RouteGroup` on `AdditiveRoutes` appears below.
//
//  See `.claude/docs/api.md`.

import BBHTTPAPI

/// What a group is gated behind.
public struct Availability: Sendable, Hashable {
  /// Machine-readable, emitted as `x-availability`.
  public let id: String
  /// One line, for the operation description.
  public let summary: String

  public init(id: String, summary: String) {
    self.id = id
    self.summary = summary
  }

  public static let always = Availability(
    id: "always",
    summary: "Always available."
  )
  public static let additiveEndpoints = Availability(
    id: "setting:additive_endpoints",
    summary: "Requires the `additive_endpoints` setting. Off by default."
  )
  public static let faceTimeSetting = Availability(
    id: "setting:facetime",
    summary: "Requires FaceTime support to be enabled. Off by default."
  )
  public static let faceTimeIncoming = Availability(
    id: "setting:facetime_incoming",
    summary: "Requires FaceTime support AND incoming-call hand-off. Both off by default."
  )
  public static let findMy = Availability(
    id: "feature:findMy",
    summary: "Requires the `findMy` feature flag. Off by default."
  )
  public static let findMySharing = Availability(
    id: "feature:findMyLocationSharing",
    summary: "Requires the `findMy` AND `findMyLocationSharing` feature flags. Both off by default."
  )
  public static let tokenAuth = Availability(
    id: "setting:auth_mode",
    summary:
      "Registered only when `auth_mode` is not `password`. Under the default these paths 404."
  )
  public static let nonLegacyCodec = Availability(
    id: "setting:codec",
    summary: "Registered only when a non-legacy payload codec is enabled."
  )
}

public struct CatalogEntry: Sendable {
  public let group: RouteGroup
  public let availability: Availability
}

public enum RouteCatalog {

  /// Every group, v1 first, then additive in the order `additiveGroups` appends them.
  ///
  /// Groups whose routes are empty are still listed: `AdditiveRoutes.security` and the
  /// FaceTime diagnostics compile to nothing outside a DEBUG build, and a release build
  /// should emit a document that says those endpoints do not exist — which it does, because
  /// the emitter skips empty groups rather than this list pretending they are present.
  public static var all: [CatalogEntry] {
    RouteTable.groups.map { CatalogEntry(group: $0, availability: .always) }
      + [CatalogEntry(group: RouteTable.landing, availability: .always)]
      + [
        CatalogEntry(group: AdditiveRoutes.security, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.alerts, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.contactAvatar, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.contactCard, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.chatPinning, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.webhookEditing, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.chatControls, availability: .additiveEndpoints),
        CatalogEntry(group: AdditiveRoutes.findMy, availability: .findMy),
        CatalogEntry(group: AdditiveRoutes.findMySharing, availability: .findMySharing),
        CatalogEntry(group: AdditiveRoutes.faceTime, availability: .faceTimeSetting),
        CatalogEntry(group: AdditiveRoutes.faceTimeIncoming, availability: .faceTimeIncoming),
        CatalogEntry(group: AdditiveRoutes.auth, availability: .tokenAuth),
        CatalogEntry(group: AdditiveRoutes.hydration, availability: .nonLegacyCodec),
      ]
  }

  /// One route, with everything needed to describe or locate it.
  public struct Entry: Sendable {
    public let group: RouteGroup
    public let route: RouteDefinition
    public let availability: Availability
    /// `/api/v1/chat/:guid/message` — the router's own form, parameters and all.
    public let path: String
  }

  /// Every route, flattened, in registration order.
  ///
  /// Order is preserved because it is load-bearing for matching a recorded path back to the
  /// template that would have served it: the router takes the first match, so anything
  /// reading this list has to as well.
  public static var routes: [Entry] {
    all.flatMap { entry in
      entry.group.routes.map {
        Entry(
          group: entry.group,
          route: $0,
          availability: entry.availability,
          path: RouteTable.path(of: $0, in: entry.group)
        )
      }
    }
  }
}
