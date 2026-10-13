//  SocketTransport+Connections
//  The bookkeeping for verified helper connections, and the one way a live connection is
//  dropped. `HelperConnections` keeps the four tables that have to move together, and
//  `drop` is the one place a live connection is forgotten, for a closed socket and a failed
//  write alike.
//
//  One slice of `SocketTransport`; the type, its stored state and the subscriber streams are
//  in `SocketTransport.swift`.

import BBPrivateAPIContract
import Foundation
import NIOCore

extension SocketTransport {

  /// The helper closed its socket.
  func remove(client channel: any Channel) {
    drop(ObjectIdentifier(channel))
    if connections.isEmpty {
      Task { await transactions.failAll(with: PrivateAPIError.notConnected) }
    }
  }

  /// Forgets a connection that is gone, however that was found out.
  ///
  /// The ONE place a connection is dropped, for a closed socket and a failed write alike,
  /// because a partial drop is wrong in both directions. Taking a registration away without
  /// announcing it leaves the runtime's state and the registry's health reporting a helper
  /// that is gone, and the close that follows finds nothing left to announce; keeping it
  /// leaves `connectedProcesses` naming a helper with no connection behind it.
  func drop(_ key: ObjectIdentifier) {
    let dropped = connections.remove(key)
    for process in dropped.processes {
      logger.info("Helper disconnected", metadata: ["process": .string(process)])
      for continuation in subscribers.values {
        continuation.yield(.helperDisconnected(process: process))
      }
    }
    failInFlight(dropped.inFlight)
  }

  /// Fails every transaction written to a connection that is gone.
  private func failInFlight(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    logger.warning(
      "A helper connection dropped with requests in flight",
      metadata: ["requests": .stringConvertible(ids.count)])
    Task {
      for id in ids { await transactions.fail(id: id, with: PrivateAPIError.notConnected) }
    }
  }
}

/// The transport's bookkeeping for its helper connections, as one value.
///
/// Four tables move together: the live connections, the order they arrived in, which helper
/// registered on which connection, and which transactions each one is carrying. Dropping a
/// connection has to touch all four, and one that misses a table reports a helper that is
/// gone, or forgets one that is not (see `SocketTransport.drop`). `remove` is the only way
/// out, and it hands back what the caller has to announce and fail.
///
/// Generic over the connection so the bookkeeping is testable without a socket.
struct HelperConnections<Connection> {

  struct Entry {
    let key: ObjectIdentifier
    let connection: Connection
  }

  /// What a dropped connection leaves for the caller: the helpers to report as gone and the
  /// transactions that can no longer be answered.
  struct Dropped: Equatable {
    var processes: [String] = []
    var inFlight: Set<String> = []
  }

  private var live: [ObjectIdentifier: Connection] = [:]
  /// Arrival order, oldest first. Untargeted traffic goes to the newest live connection.
  private var order: [ObjectIdentifier] = []
  private var registrations: [String: ObjectIdentifier] = [:]
  /// The app each connection's SOCKET serves, for the connections that arrived on one app's
  /// own socket. See `SocketTransport.Listener`.
  private var bound: [ObjectIdentifier: String] = [:]
  private var inFlight: [ObjectIdentifier: Set<String>] = [:]

  var isEmpty: Bool { live.isEmpty }
  var count: Int { live.count }
  var all: [Connection] { Array(live.values) }
  var processes: Set<String> { Set(registrations.keys) }

  /// Records a connection as the newest, superseding its own earlier position if any.
  mutating func add(_ connection: Connection, as key: ObjectIdentifier) {
    live[key] = connection
    order.removeAll { $0 == key }
    order.append(key)
  }

  /// Records which app the socket `key` arrived on serves; nil records nothing.
  mutating func bind(_ key: ObjectIdentifier, to host: String?) {
    if let host { bound[key] = host }
  }

  /// Records that `process` registered on the connection `key`, unless the connection's
  /// socket serves a different app.
  ///
  /// Not checked against `live`: a registration can be decoded before `accept` has recorded
  /// its connection, and refusing it would lose the helper's one announcement. Lookups check
  /// instead. It IS checked against the socket, because that is recorded first.
  /// - Returns: nil when registered; otherwise the app the socket serves, and nothing is
  ///   recorded.
  mutating func register(_ process: String, on key: ObjectIdentifier) -> String? {
    if let host = bound[key], host != process { return host }
    registrations[process] = key
    return nil
  }

  /// The live connection `process` registered on, or nil.
  func connection(registeredAs process: String) -> Entry? {
    guard let key = registrations[process], let connection = live[key] else { return nil }
    return Entry(key: key, connection: connection)
  }

  /// The most recently added live connection, or nil.
  var newest: Entry? { newest(servingUntargeted: false) }

  /// The most recently added live connection, or nil; with `servingUntargeted`, only one
  /// that can answer an untargeted (Messages) action: not one on another app's socket.
  func newest(servingUntargeted: Bool) -> Entry? {
    let candidate = order.last { key in
      guard live[key] != nil else { return false }
      guard servingUntargeted, let host = bound[key] else { return true }
      return host == HelperHost.messages
    }
    guard let key = candidate, let connection = live[key] else { return nil }
    return Entry(key: key, connection: connection)
  }

  mutating func carrying(_ transactionId: String, on key: ObjectIdentifier) {
    inFlight[key, default: []].insert(transactionId)
  }

  /// Forgets a finished transaction, wherever it was written.
  mutating func finished(_ transactionId: String) {
    for key in inFlight.keys { inFlight[key]?.remove(transactionId) }
  }

  /// Drops a connection and everything recorded against it.
  ///
  /// Idempotent: a write that fails and the close that follows it both arrive here, and the
  /// second finds nothing, so a helper is reported gone exactly once.
  mutating func remove(_ key: ObjectIdentifier) -> Dropped {
    live.removeValue(forKey: key)
    order.removeAll { $0 == key }
    bound.removeValue(forKey: key)
    var dropped = Dropped()
    for (process, identifier) in registrations where identifier == key {
      registrations.removeValue(forKey: process)
      dropped.processes.append(process)
    }
    dropped.processes.sort()
    dropped.inFlight = inFlight.removeValue(forKey: key) ?? []
    return dropped
  }

  mutating func removeAll() {
    live.removeAll()
    order.removeAll()
    registrations.removeAll()
    bound.removeAll()
    inFlight.removeAll()
  }
}
