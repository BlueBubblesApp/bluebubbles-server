//  SecurityHandlers
//  Blocklist and allowlist administration.
//
//  Rate limiting without an unblock path is a support burden waiting to happen, so the
//  access-control state is administered rather than silent. These endpoints are additive,
//  all `server:admin`, and nothing existing changes.
//
//  See `docs/AUTH.md`.

import BBAuth
import BBCore
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum SecurityHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some AccessControlProviding
  ) {
    registry.register(.securityListBlocked) { _ in
      .data(.array(await context.accessControl.blockedClients().map(\.json)))
    }
    registry.register(.securityUnblock) { request in
      guard let id = request.pathParameter("id").flatMap(UUID.init(uuidString:)) else {
        throw BadRequest("a valid id is required")
      }
      // Not-found rather than a 200: an id that names no block is an unblock that did not
      // happen, and answering success for it tells the caller the address is free when it
      // may still be blocked. These routes are ours (`AdditiveRoutes.security`), so 404 is
      // free to choose.
      guard await context.accessControl.unblock(id: id) else {
        throw NotFound("no blocked client has id \(id.uuidString)")
      }
      return .data(nil)
    }
    registry.register(.securityListAllowed) { _ in
      .data(.array(await context.accessControl.allowedClients().map(\.json)))
    }
    registry.register(.securityAllow) { request in
      let values = try request.values()
      let cidr = try values.requireString(
        "cidr", or: "address", message: "`cidr` or `address` is required")
      // REFUSED rather than stored. An allowlist entry that matches nothing is worse than a
      // rejected one: the person who added it believes they are covered. The service does
      // the checking, so this route and the Security page cannot disagree about what a
      // valid range is.
      guard
        let entry = await context.accessControl.allow(
          cidr: cidr, note: values["note"]?.stringValue
        )
      else {
        throw BadRequest(
          "`\(cidr)` is not an address or a CIDR block, so nothing would ever match it")
      }
      return .data(entry.json)
    }
    registry.register(.securityDisallow) { request in
      guard let id = request.pathParameter("id").flatMap(UUID.init(uuidString:)) else {
        throw BadRequest("a valid id is required")
      }
      guard await context.accessControl.disallow(id: id) else {
        throw NotFound("no allowlist entry has id \(id.uuidString)")
      }
      return .data(nil)
    }
    registry.register(.securityClearBlocked) { _ in
      await context.accessControl.clearAllBlocks()
      return .data(nil)
    }
    registry.register(.securityRecentFailures) { _ in
      // Covers addresses that are NOT blocked, so an attack is visible before it trips
      // anything, which is the difference between noticing and finding out.
      .data(.array(await context.accessControl.failures().map(\.json)))
    }
  }
}
