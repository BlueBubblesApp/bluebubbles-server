//  WriteHandlers+ChatControls
//  Muting, filtering, spam and history: the conversation controls that answer with the
//  RESULTING state, so a client never has to read back to find out what it did.
//
//  One slice of `WriteHandlers`; the entry point that registers every slice is in
//  `WriteHandlers.swift`.

import BBCore
import BBDiagnostics
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

extension WriteHandlers {
  static func registerChatControls(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & InterfaceProviding
  ) {
    registry.register(.chatMuteState) { try await chatMuteState($0, context: context) }
    registry.register(.chatMute) { try await chatMute($0, context: context) }
    registry.register(.chatUnmute) { try await chatUnmute($0, context: context) }
    registry.register(.chatFilterState) { try await chatFilterState($0, context: context) }
    registry.register(.chatPresentationState) {
      try await chatPresentationState($0, context: context)
    }
    registry.register(.chatSetFilter) { try await chatSetFilter($0, context: context) }
    registry.register(.chatMarkKnown) { try await chatMarkKnown($0, context: context) }
    for (name, isJunk): (HandlerID, Bool) in [(.chatMarkSpam, false), (.chatReportJunk, true)] {
      registry.register(name) { try await chatMarkSpamOrJunk($0, context: context, isJunk: isJunk) }
    }
    registry.register(.chatClearHistory) { try await chatClearHistory($0, context: context) }
  }

  private static func chatMuteState(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let state = try await interfaces.chat.muteState(
      guid: try request.requirePathParameter("guid")
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatMute(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let guid = try request.requirePathParameter("guid")
    let values = try request.values()
    let state = try await interfaces.chat.setMute(
      guid: guid,
      until: try Self.muteExpiry(values),
      // Defaults to true: what Messages' own toggle does.
      syncToPairedDevice: values.bool("syncToPairedDevice") ?? true
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatUnmute(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let values = try request.values()
    let state = try await interfaces.chat.unmute(
      guid: try request.requirePathParameter("guid"),
      syncToPairedDevice: values.bool("syncToPairedDevice") ?? true
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatFilterState(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let state = try await interfaces.chat.filterState(
      guid: try request.requirePathParameter("guid")
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatPresentationState(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let state = try await interfaces.chat.presentationState(
      guid: try request.requirePathParameter("guid")
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatSetFilter(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let values = try request.values()
    let category = try values.requireInt("category")
    let state = try await interfaces.chat.setFilter(
      guid: try request.requirePathParameter("guid"), category: category
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatMarkKnown(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let values = try request.values()
    let state = try await interfaces.chat.markSenderKnown(
      guid: try request.requirePathParameter("guid"),
      // Writing to the address book is opt-in. A client that omits the field is
      // accepting a sender, not editing the user's contacts.
      saveInContacts: values.bool("saveInContacts") ?? false
    )
    return .data(ChatInterface.serialize(state))
  }

  private static func chatMarkSpamOrJunk(
    _ request: APIRequestContext,
    context: some AlertProviding & InterfaceProviding,
    isJunk: Bool
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let guid = try request.requirePathParameter("guid")
    let values = try request.values()
    // FALSE by default, and this is the field that most needs it: reporting to a
    // carrier sends an SMS to a shortcode from the user's own number and cannot
    // be withdrawn.
    let toCarrier = values.bool("reportToCarrier") ?? false
    let dryRun = values.bool("dryRun") ?? false

    let result =
      isJunk
      ? try await interfaces.chat.reportJunk(
        guid: guid, reportToCarrier: toCarrier, dryRun: dryRun
      )
      : try await interfaces.chat.markSpam(
        guid: guid, reportToCarrier: toCarrier, dryRun: dryRun
      )

    if !dryRun {
      // A remote client just reclassified a conversation on every device on
      // this account. Logging that is not enough: the person at the Mac is
      // the one who has to undo it if it was not them.
      await context.alerts.raise(
        UserAlert(
          severity: .warning,
          title: isJunk ? "A chat was reported as junk" : "A chat was marked as spam",
          body: "\(guid): \(result.messageCount) message(s)"
            + (toCarrier ? ", reported to the carrier" : "")
            + ". This came from an API client.",
          source: "Chat"
        )
      )
    }
    return .data(ChatInterface.serialize(result))
  }

  /// Empties a conversation. The conversation itself stays; `chat.delete` is the one
  /// that removes it.
  private static func chatClearHistory(
    _ request: APIRequestContext,
    context: some AlertProviding & InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let guid = try request.requirePathParameter("guid")
    let values = try request.values()

    // An explicit confirmation, because this is not recoverable and the URL alone is
    // one typo away from a conversation nobody meant to empty. Deliberately NOT a
    // query parameter: those get copied between requests.
    guard values.bool("confirm") == true else {
      throw BadRequest(
        "clearing a chat's history is not reversible: send `{\"confirm\": true}`"
      )
    }

    let deleted = try await interfaces.chat.clearHistory(guid: guid)
    await context.alerts.raise(
      UserAlert(
        severity: .warning,
        title: "A chat's history was cleared",
        body: "\(guid) was emptied by an API client. The messages are gone from "
          + "every device on this account.",
        source: "Chat"
      )
    )
    return .data(.object(["deleted": .bool(deleted)]))
  }

  /// When a mute should lift, from whichever form the client sent.
  ///
  /// Three accepted spellings, and the ABSENCE of all three means indefinitely, which is
  /// the common case ("Hide Alerts") and should not require a magic value:
  ///
  ///   - `mutedUntil`: epoch milliseconds, matching every other timestamp on this API, or
  ///     an ISO 8601 string, because half the clients that talk to this server send those
  ///     and rejecting them buys nothing.
  ///   - `durationSeconds`: relative, computed against the SERVER's clock. This exists
  ///     because a phone with a skewed clock computing an absolute instant is how a
  ///     one-hour mute becomes a mute that already expired.
  ///   - `indefinite: true`: explicit, for a client that would rather say so.
  static func muteExpiry(_ values: RequestValues) throws -> Date? {
    if values.bool("indefinite") == true { return nil }

    if let seconds = values.double("durationSeconds") {
      guard seconds > 0 else {
        throw BadRequest("`durationSeconds` must be greater than zero")
      }
      return Date().addingTimeInterval(seconds)
    }

    guard let raw = values["mutedUntil"], raw != .null else { return nil }
    if let milliseconds = raw.numberValue {
      return Date(epochMilliseconds: milliseconds)
    }
    if let text = raw.stringValue, let parsed = WireDate.parse(text) {
      return parsed
    }
    throw BadRequest(
      "`mutedUntil` must be epoch milliseconds or an ISO 8601 date"
    )
  }
}
