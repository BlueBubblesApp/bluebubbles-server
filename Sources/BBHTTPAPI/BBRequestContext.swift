//  BBRequestContext
//  The router's per-request context: Hummingbird's, plus the peer address.

import Hummingbird
import HummingbirdCore
import NIOCore

/// The router's context, carrying the connection's peer address.
///
/// `BasicRequestContext` drops it: it is handed the channel at construction and keeps only
/// the logger. Without this type `APIRequestContext.peerAddress` is always nil, every client
/// resolves as `.unresolved`, and the per-client half of `AccessControlService` (the block
/// list, the lockout escalation, the `X-Forwarded-For` trust rules) never engages at all.
/// That is silent: nothing fails, the throttle just never fires.
///
/// `RemoteAddressRequestContext` is Hummingbird's own protocol for this, so conforming to it
/// also gives the framework's tracing middleware the address for free.
public struct BBRequestContext: RequestContext, RemoteAddressRequestContext {
  public var coreContext: CoreRequestContextStorage
  /// nil for a request that did not arrive over a socket with an address: a UNIX-domain
  /// or in-process channel. Treated as unresolved rather than as a client, which is the
  /// safe direction: unresolved never blocks anyone.
  public let remoteAddress: SocketAddress?

  public init(source: ApplicationRequestContextSource) {
    self.coreContext = .init(source: source)
    self.remoteAddress = source.channel.remoteAddress
  }
}

extension SocketAddress {
  /// The address alone, without the port.
  ///
  /// The port must not be part of client identity: every request from one client arrives
  /// on a different ephemeral port, so keying on it would give each request its own
  /// counter and no failure would ever accumulate.
  public var bbClientAddress: String? {
    switch self {
    case .v4, .v6: ipAddress
    case .unixDomainSocket: nil
    }
  }
}
