//  SendCache
//  One `tempGuid`, one send.
//
//  A client picks a `tempGuid` for a send so it can recognise the message when it comes back.
//  This server echoed it on the response and kept no record, so a client that retried a send
//  it never got an answer to sent the message a SECOND TIME, into a real conversation, with
//  nothing to notice.
//
//  **The hydration work widened the window rather than narrowing it.** Every message-bearing
//  route now holds its response until the row appears in `chat.db` — up to 60 seconds for a
//  send, 30 for an edit (`SendHydrationPolicy`) — so a client with a 30-second timeout is
//  MORE likely to retry than when the answer came back immediately. The retry is the client
//  behaving correctly; sending twice is this server's part to fix.
//
//  WHAT THE REFERENCE DOES, AND WHY THIS IS NOT A TRANSCRIPTION
//  The reference keeps an `EventCache` of temp GUIDs, and its HTTP routes `add` before the
//  send and `remove` after — but they never `find`, so on the HTTP surface the cache changes
//  nothing. The only reader is its SOCKET send path, which refuses a duplicate with
//  "Message is already queued to be sent (Temp GUID: …)!". This server has no inbound socket
//  commands at all (`SocketServer`'s header records that as a decision), so transcribing the
//  cache literally would add a structure nothing reads.
//
//  So the claim is applied where this server's clients actually send, and the refusal is the
//  reference's own sentence. It is a decision to be stricter than the reference on HTTP, and
//  a narrow one: only a duplicate while the first is STILL IN FLIGHT is refused. Once a send
//  finishes the claim is released and the same `tempGuid` sends again, which is what makes
//  this different from an idempotency key.
//
//  The TTL is the backstop that matters. A claim that leaked — a crash between claiming and
//  releasing, a path that throws somewhere unforeseen — must not lock a client out of its own
//  `tempGuid` forever. The reference purges its cache every six hours, which would be exactly
//  that lockout; this expires each claim on its own, a little past the longest hydration wait.

import BBCore
import Foundation

/// Tracks which `tempGuid`s have a send in flight.
public actor SendCache {

  /// Twice the 60-second send ceiling. Long enough that a legitimately slow send still holds
  /// its claim for the whole hydration wait, short enough that a leaked one is a two-minute
  /// annoyance rather than a dead `tempGuid`.
  public static let defaultTTL: Duration = .seconds(120)

  /// Bounded, because the key is client-supplied: a client looping on a fresh GUID must not
  /// be able to grow this without limit. At the cap the oldest claim is dropped, which at
  /// worst allows the duplicate this exists to prevent — the same outcome as not having the
  /// cache, and never a refusal of a legitimate send.
  public static let defaultCapacity = 4096

  private var claims: BoundedCache<String, Bool>

  public init(capacity: Int = SendCache.defaultCapacity, ttl: Duration = SendCache.defaultTTL) {
    claims = BoundedCache(capacity: capacity, ttl: ttl)
  }

  /// Claims a `tempGuid` for the send about to start.
  ///
  /// - Returns: false when one is already in flight, which is the caller's cue to refuse.
  ///   An absent or empty id is always claimable: a client that named nothing cannot be
  ///   deduplicated, and refusing every anonymous send would break every client that does
  ///   not send one.
  public func claim(_ tempGUID: String?) -> Bool {
    guard let tempGUID, !tempGUID.isEmpty else { return true }
    if claims[tempGUID] != nil { return false }
    claims.insert(true, for: tempGUID)
    return true
  }

  /// Releases a claim, whether the send succeeded or failed.
  ///
  /// Failure releases too, and deliberately: a send that failed is one the client SHOULD be
  /// able to retry, and holding the claim would turn one failure into two minutes of
  /// refusals.
  public func release(_ tempGUID: String?) {
    guard let tempGUID, !tempGUID.isEmpty else { return }
    claims.remove(tempGUID)
  }

  /// How many claims are outstanding. For tests and diagnostics.
  public var count: Int { claims.count }
}

/// Composed by the send handlers alone; see `HandlerCapabilities`.
public protocol SendDeduplicating: Sendable {
  var sendCache: SendCache { get }
}
