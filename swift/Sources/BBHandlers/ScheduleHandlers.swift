//  ScheduleHandlers
//  Controllers for scheduled messages.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum ScheduleHandlers {

  public static func register(into registry: inout HandlerRegistry, context: some ScheduleProviding)
  {
    registry.register(.scheduleList) { request in
      let status = request.queryParameters["status"]
        .flatMap(ScheduleInterface.Status.init(rawValue:))
      return .data(.array(try await context.schedule.list(status: status).map(\.json)))
    }

    registry.register(.scheduleFind) { request in
      return .data(try await context.schedule.find(id: try request.identifier()).json)
    }

    registry.register(.scheduleCreate) { request in
      return .data(try await context.schedule.create(try request.jsonBody() ?? .object([:])).json)
    }

    registry.register(.scheduleUpdate) { request in
      return .data(
        try await context.schedule.update(
          id: try request.identifier(), body: try request.jsonBody() ?? .object([:])
        ).json)
    }

    registry.register(.scheduleDelete) { request in
      try await context.schedule.delete(id: try request.identifier())
      return .data(nil)
    }
  }
}

extension APIRequestContext {
  /// The `:id` path parameter as a number.
  func identifier() throws -> Int64 {
    let raw = try requirePathParameter("id")
    guard let id = Int64(raw) else { throw BadRequest("`id` must be a number") }
    return id
  }
}
