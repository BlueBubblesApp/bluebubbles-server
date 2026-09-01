//  HydrationHandlers
//  `POST /api/v1/message/hydrate` — the other half of reference-v2.
//
//  Registered only when a non-legacy codec is enabled. A client on `legacy-v1` never needs
//  it, and an endpoint nobody calls is still an endpoint an attacker can.
//
//  Batched because notifications arrive in bursts: a group chat waking up produces a dozen at
//  once, and a dozen round trips on a phone radio is a materially worse experience than one.
//
//  See `docs/EVENTS.md`.

import BBEvents
import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBSerialization
import Foundation

public enum HydrationHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some InterfaceProviding
  ) {
    registry.register("message.hydrate") { request in
      try await self.hydrate(request, context: context)
    }
  }

  private static func hydrate(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    guard let body = try request.jsonBody() else {
      throw BadRequest("a JSON body with `guids` is required")
    }
    let guids = body["guids"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let hydration = HydrationRequest(
      guids: guids,
      withAttachments: body["withAttachments"]?.boolValue ?? false
    )

    do {
      try hydration.validate()
    } catch HydrationRequest.ValidationError.empty {
      throw BadRequest("`guids` must not be empty")
    } catch HydrationRequest.ValidationError.tooMany(let count, let limit) {
      throw BadRequest("asked for \(count) messages; the limit is \(limit)")
    }

    let interfaces = try await context.requireInterfaces()
    let results = try await interfaces.message.hydrate(guids: hydration.uniqueGUIDs)

    // A guid that no longer resolves is omitted rather than erroring the batch: a
    // message deleted between the notification and the hydration is normal, and failing
    // the whole request would lose the eleven that were fine.
    return .data(
      .array(results),
      metadata: .object([
        "requested": .int(hydration.uniqueGUIDs.count),
        "returned": .int(results.count),
      ]))
  }
}
