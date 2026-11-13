//  RequestBodies+FindMy
//  The Find My routes' bodies: refreshing a friend, and requesting, starting and stopping a
//  share.
//
//  Its own file so the Find My surface is read on its own. The declaration model, the rules
//  and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let findMyBodies: [HandlerID: Body] = [
    // MARK: Find My

    .findmyRefreshFriend: Body(
      summary:
        "Asks Apple for one friend's location now, rather than waiting for the next "
        + "broadcast. Rate limited: a refresh that comes too soon answers 200 with the "
        + "CACHED location and `metadata.refreshed` false, plus the seconds to wait.",
      properties: [
        Property(
          "address", .string,
          "The friend to locate, as their handle appears in `GET icloud/findmy/friends`.",
          required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .findmyRequestShare: Body(
      summary:
        "Asks someone to share their location with this account. Answers as soon as the "
        + "invitation is sent; whether it is accepted happens on their device, minutes or "
        + "days later, so nothing here reports that it was.",
      properties: [
        Property(
          "address", .string,
          "Who to ask. A phone number or email address they use with Find My.", required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .findmyStartSharing: Body(
      summary:
        "Shares this Mac's location with a conversation, or with one person in it. Behind "
        + "the `findmy_location_sharing` feature switch: with it off the route answers 403 "
        + "and names the setting.",
      properties: [
        chatGUID(
          "The conversation to share with. Required even when `address` names one person: "
            + "IMCore uses the chat to pick which of this account's addresses the offer is "
            + "sent from, and there is no chat-less form of the call."),
        Property(
          "address", .string,
          "One participant to share with. Absent shares with everyone in the chat."),
        Property(
          "duration", .string,
          "`one-hour`, `until-end-of-day` or `indefinitely`. Defaults to `one-hour`. The "
            + "three IMCore accepts and no more: any other value produces an indefinite "
            + "share, which is not what a client asking for an hour meant."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("duration", .string("one-hour")),
      ])),

    .findmyStopSharing: Body(
      summary:
        "Stops sharing this Mac's location with a conversation, or with one person in it. "
        + "Behind the same feature switch as the start.",
      properties: [
        chatGUID("The conversation to stop sharing with."),
        Property(
          "address", .string,
          "One participant to stop sharing with. Absent stops sharing with everyone in the "
            + "chat."),
      ],
      example: .obj([("chatGuid", .string("iMessage;-;+15551234567"))])),

  ]
}
