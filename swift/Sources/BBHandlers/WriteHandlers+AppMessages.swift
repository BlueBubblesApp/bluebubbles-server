//  WriteHandlers+AppMessages
//  App balloons and polls: a payload the server builds for an iMessage app, and the
//  polls that are one such app on the wire.
//
//  One slice of `WriteHandlers`; the entry point that registers every slice is in
//  `WriteHandlers.swift`.

import BBDiagnostics
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

extension WriteHandlers {
  static func registerAppMessages(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding
  ) {
    registry.register(.messageAppPayload) { request in
      let interfaces = try await context.requireInterfaces()
      let message = try await interfaces.message.appMessage(
        guid: try request.requirePathParameter("guid"))
      return .data(interfaces.message.serialize(message))
    }

    registry.register(.messageSendApp) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // Exactly one payload shape. `url` is the escape hatch for an app whose format is
      // neither of the two the server can build; `json` and `fields` save a client from
      // base64ing or percent-encoding anything itself.
      let payload: MessageInterface.AppPayload
      if let url = values.string("url") {
        payload = .url(url)
      } else if let json = values["json"] {
        payload = .json(json)
      } else if let fields = try Self.appPayloadFields(values["fields"]) {
        payload = .fields(fields)
      } else {
        throw BadRequest("one of `url`, `json` or `fields` is required")
      }
      let sent = try await interfaces.message.sendAppMessage(
        chatGUID: try values.requireString("chatGuid"),
        balloonBundleID: try values.requireString("balloonBundleId"),
        payload: payload,
        sessionID: values.string("sessionId"),
        appName: values.string("appName"),
        appID: values.int("appId"),
        summary: values.string("summary"),
        caption: values.string("caption")
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageSendGamePigeon) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // `fields` is an ORDERED list of {name, value}; a plain object is accepted too, for
      // the games that do not care about order.
      guard let fields = try Self.appPayloadFields(values["fields"]) else {
        throw BadRequest("`fields` is required, as a list of {name, value} or an object")
      }
      let sent = try await interfaces.message.sendGamePigeon(
        chatGUID: try values.requireString("chatGuid"),
        version: values.int("version") ?? 52,
        fields: fields,
        sessionID: values.string("sessionId"),
        caption: values.string("caption"),
        teamID: values.string("teamId") ?? "EWFNLB79LQ"
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageCreatePoll) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let options = (values.array("options") ?? []).compactMap(\.stringValue)
      let sent = try await interfaces.message.createPoll(
        chatGUID: try values.requireString("chatGuid"),
        title: values.string("title") ?? "",
        options: options
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messagePoll) { request in
      let interfaces = try await context.requireInterfaces()
      let poll = try await interfaces.message.poll(guid: try request.requirePathParameter("guid"))
      return .data(interfaces.message.serialize(poll))
    }

    registry.register(.messageAddPollOption) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let sent = try await interfaces.message.addPollOption(
        chatGUID: try values.requireString("chatGuid"),
        pollGUID: try request.requirePathParameter("guid"),
        text: try values.requireString("text")
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageVotePoll) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // The voter's COMPLETE selection; an empty array retracts every vote.
      let optionIDs = (values.array("optionIds") ?? []).compactMap(\.stringValue)
      let sent = try await interfaces.message.votePoll(
        chatGUID: try values.requireString("chatGuid"),
        pollGUID: try request.requirePathParameter("guid"),
        optionIDs: optionIDs
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }
  }

  /// `fields` as either an ordered list of `{name, value}` or a plain object.
  ///
  /// The list is the honest form (a query string may repeat a name and some apps care
  /// about order) but an object is what most callers will reach for, so it is accepted and
  /// sorted by name to at least be deterministic.
  static func appPayloadFields(
    _ value: JSONValue?
  ) throws -> [(name: String, value: String)]? {
    if let array = value?.arrayValue {
      return try array.map { entry in
        guard let name = entry["name"]?.stringValue else {
          throw BadRequest("every entry in `fields` needs a `name`")
        }
        return (name: name, value: entry["value"]?.stringValue ?? "")
      }
    }
    if case .object(let map)? = value {
      return map.map { (name: $0.key, value: $0.value.stringValue ?? "") }
        .sorted { $0.name < $1.name }
    }
    return nil
  }
}
