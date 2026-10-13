//  SubscriptionTier
//  What a license entitles a server to, as an ordered value.
//
//  ONE TIER SHIPS. The type does not know that, and that is the point: `pro` is a value in a
//  list rather than a case in an enum, so adding a second tier later is a declaration and not
//  a refactor. There is deliberately no `isPro` boolean anywhere in this package — that is the
//  shape that would have to be torn out, and it is cheaper never to write it.
//
//  THE RANK TRAVELS IN THE TOKEN, and that is the load-bearing decision here. A server only
//  knows the tiers its own build was compiled with, but tokens are issued by a service that
//  moves faster than installed servers do. Without a rank on the wire, a customer on a tier
//  introduced after their server shipped would present a tier id the server had never heard of
//  and be refused everything — the exact customer who paid the most. With the rank on the wire
//  an unknown tier still ORDERS, so a higher tier satisfies a lower floor on a server that has
//  never been told the new tier exists.
//
//  Consequently `id` is identity and `rank` is order, and they are deliberately not the same
//  question. Two values with the same id ARE the same tier even if one carries a stale rank;
//  comparison always uses the rank the token supplied. See `==` and `<` below.

import Foundation

public struct SubscriptionTier: Sendable, Hashable, Comparable, CustomStringConvertible {

  /// Stable, lowercase, and API: it appears in tokens and in the 402 body, so it may never be
  /// renamed. Not an enum for the reason in the header.
  public let id: String

  /// Ordering only. Higher is more entitled; gaps are allowed and expected, so a tier can be
  /// inserted between two existing ones without renumbering anything already issued.
  public let rank: Int

  /// For a person. Falls back to the id for a tier this build does not know.
  public let displayName: String

  public init(id: String, rank: Int, displayName: String) {
    self.id = id
    self.rank = rank
    self.displayName = displayName
  }

  /// A tier named by a token that this build has never heard of.
  ///
  /// Not a failure. The rank is what decides access (see the header), so an unrecognised tier
  /// is perfectly usable — it simply has no nicer name to show than its id.
  public init(unknownID id: String, rank: Int) {
    self.init(id: id, rank: rank, displayName: id)
  }

  public var description: String { id }

  // MARK: - Declarations

  /// The paid tier.
  ///
  /// Rank 1 rather than 0 so "no license at all" has a rank below every tier without needing a
  /// sentinel value or an optional comparison.
  public static let pro = SubscriptionTier(id: "pro", rank: 1, displayName: "Pro")

  /// Every tier this build knows, lowest first.
  ///
  /// The list a client is shown, and the list a token id is resolved against. A tier that is
  /// planned but not being sold does not appear here — an unsold tier in this list is an
  /// advertised product.
  public static let shipped: [SubscriptionTier] = [pro]

  /// The known tier with this id, if this build knows it.
  public static func known(id: String) -> SubscriptionTier? {
    shipped.first { $0.id == id }
  }

  /// Resolves a tier from what a token carried.
  ///
  /// Prefers this build's own declaration when the id is recognised, so the display name is
  /// the good one, but keeps the TOKEN's rank: the issuer is the authority on ordering, and a
  /// build whose idea of a rank has drifted must not silently re-rank a paid entitlement.
  public static func resolve(id: String, rank: Int) -> SubscriptionTier {
    guard let known = known(id: id) else { return SubscriptionTier(unknownID: id, rank: rank) }
    return SubscriptionTier(id: known.id, rank: rank, displayName: known.displayName)
  }

  // MARK: - Identity and order are different questions

  /// Identity is the id alone. A tier decoded from a token is the same tier as the one
  /// declared above even if the ranks have drifted between issuer and build.
  public static func == (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) { hasher.combine(id) }

  /// Order is the rank alone, which is what makes an unknown tier usable.
  public static func < (lhs: SubscriptionTier, rhs: SubscriptionTier) -> Bool {
    lhs.rank < rhs.rank
  }

  /// Whether holding this tier satisfies a route or service asking for `floor`.
  public func satisfies(_ floor: SubscriptionTier) -> Bool { rank >= floor.rank }
}
