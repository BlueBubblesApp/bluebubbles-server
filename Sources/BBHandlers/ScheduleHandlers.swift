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
      let message = try ScheduleInterface.NewMessage(v1: try request.values().raw)
      return .data(try await context.schedule.create(message).json)
    }

    registry.register(.scheduleUpdate) { request in
      let id = try request.identifier()
      let change = ScheduleInterface.Change(v1: try request.values().raw)
      return .data(try await context.schedule.update(id: id, change).json)
    }

    registry.register(.scheduleDelete) { request in
      try await context.schedule.delete(id: try request.identifier())
      return .data(nil)
    }
  }
}
