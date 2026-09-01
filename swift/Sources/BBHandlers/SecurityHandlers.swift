//  SecurityHandlers
//  Blocklist and allowlist administration.
//
//  Rate limiting without an unblock path is a support burden waiting to happen, so the
//  access-control state is administered rather than silent. These endpoints are additive,
//  all `server:admin`, and nothing existing changes.
//
//  See `docs/AUTH.md`.

import BBAuth
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum SecurityHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some AccessControlProviding
  ) {
    registry.register("security.listBlocked") { _ in
      .data(.array(await context.accessControl.blockedClients().map(encode)))
    }
    registry.register("security.unblock") { request in
      guard let raw = request.pathParameters["id"], let id = UUID(uuidString: raw) else {
        throw BadRequest("a valid id is required")
      }
      await context.accessControl.unblock(id: id)
      return .data(nil)
    }
    registry.register("security.listAllowed") { _ in
      .data(.array(await context.accessControl.allowedClients().map(encode)))
    }
    registry.register("security.allow") { request in
      let values = try request.values()
      let cidr = try values.requireString(
        "cidr", or: "address", message: "`cidr` or `address` is required")
      let entry = await context.accessControl.allow(
        cidr: cidr, note: values["note"]?.stringValue
      )
      return .data(encode(entry))
    }
    registry.register("security.disallow") { request in
      guard let raw = request.pathParameters["id"], let id = UUID(uuidString: raw) else {
        throw BadRequest("a valid id is required")
      }
      await context.accessControl.disallow(id: id)
      return .data(nil)
    }
    registry.register("security.clearBlocked") { _ in
      await context.accessControl.clearAllBlocks()
      return .data(nil)
    }
    registry.register("security.recentFailures") { _ in
      // Covers addresses that are NOT blocked, so an attack is visible before it trips
      // anything — which is the difference between noticing and finding out.
      .data(.array(await context.accessControl.failures().map(encode)))
    }
  }

  /// Built up rather than written as one literal: a dictionary literal this size with
  /// mixed inferred types takes the type checker past its budget.
  private static func encode(_ client: BlockedClient) -> JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["id"] = .string(client.id.uuidString)
    fields["address"] = .string(client.address)
    fields["reason"] = .string(client.reason)
    fields["failure_count"] = .int(client.failureCount)
    fields["first_seen_at"] = .int64(milliseconds(client.firstSeen))
    fields["last_seen_at"] = .int64(milliseconds(client.lastSeen))
    fields["blocked_at"] = .int64(milliseconds(client.blockedAt))
    fields["is_permanent"] = .bool(client.isPermanent)
    if let expiresAt = client.expiresAt {
      fields["expires_at"] = .int64(milliseconds(expiresAt))
    }
    return .object(fields)
  }

  /// Epoch milliseconds, matching every other date on this wire.
  private static func milliseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
  }

  private static func encode(_ client: AllowedClient) -> JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["id"] = .string(client.id.uuidString)
    fields["cidr"] = .string(client.cidr)
    fields["created_at"] = .int64(milliseconds(client.createdAt))
    if let note = client.note { fields["note"] = .string(note) }
    return .object(fields)
  }

  private static func encode(_ failure: AuthFailureRecord) -> JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["id"] = .string(failure.id.uuidString)
    // Optional: a failure whose client address could not be established is exactly the
    // degraded case the policy plans for, and it still belongs in the record.
    if let address = failure.address { fields["address"] = .string(address) }
    fields["at"] = .int64(milliseconds(failure.at))
    fields["path"] = .string(failure.path)
    fields["reason"] = .string(failure.reason)
    return .object(fields)
  }
}
