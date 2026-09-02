//  FindMyRuntime
//  The in-memory half of FindMy: who is where, and how often Apple may be asked.

import BBCore
import BBSystem

/// Shared by every client on purpose: several are connected by design, and Apple counts this
/// server as one. See `IntervalGate`.
public final class FindMyRuntime: Sendable {

  /// Global gate on the friends refresh, which is the only route that reaches Apple.
  ///
  /// Fifteen seconds is well inside what a person pressing refresh perceives as immediate,
  /// and well outside anything that looks like polling from Apple's side.
  public let refreshGate = IntervalGate(interval: .seconds(15))

  /// Refreshing ONE person, gated separately and more loosely.
  ///
  /// A per-handle refresh is a single locate request rather than one per friend, so holding
  /// it to the same fifteen seconds as the bulk refresh would make the cheap call as
  /// expensive to use as the costly one.
  public let handleRefreshGate = IntervalGate(interval: .seconds(3))

  /// Where people are, as the server currently understands it.
  ///
  /// Friends have no cache file — unlike devices, they exist only in memory, fed by the
  /// helper. See `FindMyFriendsCache`.
  public let friends = FindMyFriendsCache()

  public init() {}
}
