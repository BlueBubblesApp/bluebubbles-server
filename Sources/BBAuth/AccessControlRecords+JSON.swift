//  AccessControlRecords+JSON
//  The `security/*` routes' wire shapes, on the records themselves.
//
//  On the records, the way `Webhook.json` and `ScheduledMessage.json` are, so the projection is
//  one step any caller can take and the handlers stay parse, call, serialize. Every date is
//  epoch milliseconds, matching every other date on this wire. Each object is built up rather
//  than written as one literal: a dictionary literal this size with mixed inferred types takes
//  the type checker past its budget.

import BBCore
import Foundation

extension BlockedClient {
  public var json: JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["id"] = .string(id.uuidString)
    fields["address"] = .string(address)
    fields["reason"] = .string(reason)
    fields["failure_count"] = .int(failureCount)
    fields["first_seen_at"] = .int64(firstSeen.epochMilliseconds)
    fields["last_seen_at"] = .int64(lastSeen.epochMilliseconds)
    fields["blocked_at"] = .int64(blockedAt.epochMilliseconds)
    fields["is_permanent"] = .bool(isPermanent)
    if let expiresAt {
      fields["expires_at"] = .int64(expiresAt.epochMilliseconds)
    }
    return .object(fields)
  }
}

extension AllowedClient {
  public var json: JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["id"] = .string(id.uuidString)
    fields["cidr"] = .string(cidr)
    fields["created_at"] = .int64(createdAt.epochMilliseconds)
    if let note { fields["note"] = .string(note) }
    return .object(fields)
  }
}

extension AuthFailureRecord {
  public var json: JSONValue {
    var fields: [String: JSONValue] = [:]
    fields["id"] = .string(id.uuidString)
    // Optional: a failure whose client address could not be established is exactly the
    // degraded case the policy plans for, and it still belongs in the record.
    if let address { fields["address"] = .string(address) }
    fields["at"] = .int64(at.epochMilliseconds)
    fields["path"] = .string(path)
    fields["reason"] = .string(reason)
    return .object(fields)
  }
}
