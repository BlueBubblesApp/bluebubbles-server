//  RequestBodies+Chats
//  The conversation routes' bodies: creation and administration, and the state changes
//  (mute, mark known, mark spam, report junk, filters, history) whose fields decide what the
//  request does.
//
//  Its own file so a client author changing a chat opens these and not the message routes.
//  The declaration model, the rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let chatBodies: [HandlerID: Body] = [
    // MARK: Conversation state
    //
    // Small bodies, but every field here changes what the request DOES (a spam report
    // that reaches a carrier cannot be withdrawn) so none of them should be discovered
    // by trial and error.

    .chatUnmute: Body(
      summary: "Unmutes a conversation and answers with the resulting state.",
      properties: [
        Property(
          "syncToPairedDevice", .boolean,
          "Push the change to the user's other devices. Defaults to true, which is what "
            + "Messages' own toggle does.")
      ],
      example: .obj([("syncToPairedDevice", .bool(true))]),
      required: false),

    .chatMarkKnown: Body(
      summary: "Accepts a sender, moving the conversation out of Unknown Senders.",
      properties: [
        Property(
          "saveInContacts", .boolean,
          "Also write the sender to the address book. Defaults to FALSE: accepting a "
            + "sender is not the same as editing the user's contacts.")
      ],
      example: .obj([("saveInContacts", .bool(false))]),
      required: false),

    .chatMarkSpam: Body(
      summary: "Marks a conversation as spam.",
      properties: [
        Property(
          "reportToCarrier", .boolean,
          "Also report it to the carrier. Defaults to FALSE, and think before setting it: "
            + "the report is an SMS sent from the user's own number and cannot be undone."),
        Property(
          "dryRun", .boolean,
          "Answer with what would happen and change nothing. Defaults to false."),
      ],
      example: .obj([("reportToCarrier", .bool(false)), ("dryRun", .bool(true))]),
      required: false),

    .chatReportJunk: Body(
      summary: "Reports a conversation as junk, which also deletes it locally.",
      properties: [
        Property(
          "reportToCarrier", .boolean,
          "Also report it to the carrier. Defaults to FALSE, and the report is an SMS from "
            + "the user's own number that cannot be withdrawn."),
        Property(
          "dryRun", .boolean,
          "Answer with what would happen and change nothing. Defaults to false."),
      ],
      example: .obj([("reportToCarrier", .bool(false)), ("dryRun", .bool(true))]),
      required: false),

    // MARK: Conversation administration

    .chatCreate: Body(
      summary:
        "Creates a conversation and answers with the whole chat: its participants, and the "
        + "message the create sent. What is possible depends on the configuration — the "
        + "Private API creates either kind and needs no first message; without it a "
        + "ONE-TO-ONE chat is created by sending `message` through AppleScript, and a GROUP "
        + "needs the user-installed Shortcut.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "Who the conversation is with. One address makes a one-to-one chat, two or more a "
            + "group.", required: true),
        Property(
          "message", .string,
          "The first message. Optional with the Private API, REQUIRED without it: there is "
            + "no other way to bring a chat into existence, so a create with no message is "
            + "refused with that as the reason."),
        Property(
          "service", .string, "`iMessage` or `SMS`. Defaults to `iMessage`."),
        Property(
          "method", .string,
          "`apple-script` or `private-api`. Accepted, and NOT acted on: this server chooses "
            + "the backend from what it has, so naming one cannot force it. Documented "
            + "because clients send it and the reference validates it."),
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the message the create sent, so a client can "
            + "match it to the row it inserted optimistically."),
      ],
      examples: [
        Example(
          "one-to-one",
          "A new chat with one person.",
          "Works on every configuration. Without the Private API the chat comes into "
            + "existence as a side effect of sending `message`, which is why it is here.",
          .obj([
            ("addresses", .array([.string("+15551234567")])),
            ("service", .string("iMessage")),
            ("message", .string("Hey!")),
            ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
          ])),
        Example(
          "group",
          "A new group chat.",
          "Needs the Private API or the installed Shortcut. A server with neither refuses "
            + "this and names the setting that fixes it rather than failing generically.",
          .obj([
            (
              "addresses",
              .array([
                .string("+15551234567"), .string("+15557654321"),
                .string("someone@example.com"),
              ])
            ),
            ("service", .string("iMessage")),
            ("message", .string("Making a group for the weekend")),
          ])),
      ]),

    .chatUpdate: Body(
      summary:
        "Renames a GROUP conversation. A body with no `displayName` answers 200 and changes "
        + "nothing, as the reference does; renaming a one-to-one chat is refused, because "
        + "Messages accepts that request, reports success and does nothing.",
      properties: [
        Property(
          "displayName", .string,
          "The new group name, at least one character. An empty string is a 400: omit the "
            + "field to change nothing, rather than sending one.")
      ],
      example: .obj([("displayName", .string("Weekend plans"))]),
      required: false),

    .chatAddParticipant: Body(
      summary:
        "Adds someone to a group conversation. Two routes share this: `POST :guid/participant` "
        + "is the older spelling and `POST :guid/participant/add` the newer, and both ship.",
      properties: [
        Property(
          "address", .string,
          "The phone number or email address to add. Accepted as a query parameter too, "
            + "which is what makes the DELETE spelling of the removal route usable.",
          required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .chatRemoveParticipant: Body(
      summary:
        "Removes someone from a group conversation. Two routes share this: "
        + "`DELETE :guid/participant` is the older spelling and "
        + "`POST :guid/participant/remove` the newer, and both ship.",
      properties: [
        Property(
          "address", .string,
          "The participant to remove, as it appears in the chat's `participants`. Accepted "
            + "as a query parameter too, for clients whose HTTP layer will not put a body on "
            + "a DELETE.", required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    // MARK: Conversation state, macOS 26

    .chatMute: Body(
      summary:
        "Mutes a conversation and answers with the resulting state. THREE WAYS TO SAY WHEN, "
        + "and sending none of them mutes indefinitely, which is what Messages' own Hide "
        + "Alerts does and should not need a magic value.",
      properties: [
        Property(
          "mutedUntil", .anything,
          "When the mute lifts: epoch MILLISECONDS, or an ISO 8601 string. Absolute, so a "
            + "device with a skewed clock is computing the instant itself."),
        Property(
          "durationSeconds", .number,
          "How long to mute for, counted from the SERVER's clock. This is the one to send "
            + "from a phone: it is what keeps a one-hour mute from arriving already expired."),
        Property(
          "indefinite", .boolean,
          "`true` mutes until something unmutes it, and wins over the other two. The same as "
            + "sending none of them, for a client that would rather say so."),
        Property(
          "syncToPairedDevice", .boolean,
          "Push the change to the user's other devices. Defaults to true, which is what "
            + "Messages' own toggle does."),
      ],
      examples: [
        Example(
          "hide-alerts",
          "Mute until something unmutes it.",
          "The common case, and the one an empty body already does. Sending `indefinite` "
            + "says so out loud rather than relying on the absence of the other fields.",
          .obj([("indefinite", .bool(true)), ("syncToPairedDevice", .bool(true))])),
        Example(
          "for-an-hour",
          "Mute for a fixed length of time.",
          "Relative, so the server does the arithmetic. A phone computing the instant itself "
            + "is how a one-hour mute becomes one that already lapsed.",
          .obj([("durationSeconds", .int(3600))])),
        Example(
          "until-a-moment",
          "Mute until a particular time.",
          "Epoch milliseconds, matching every other timestamp on this API; an ISO 8601 "
            + "string is accepted too, because half the clients that reach this server send "
            + "those.",
          .obj([("mutedUntil", .int(1_788_440_082_220))])),
      ],
      required: false),

    .chatSetFilter: Body(
      summary:
        "Moves a conversation between the sidebar's filter buckets. Only the three buckets "
        + "this Mac has been observed to use are accepted: IMCore takes any number, and a "
        + "conversation put in a bucket Messages has no row for leaves the inbox and appears "
        + "nowhere, with a 200 saying it worked.",
      properties: [
        Property(
          "category", .integer,
          "`0` inbox, `1` unknown senders, `2` junk. Anything else is refused, naming the "
            + "three.", required: true)
      ],
      example: .obj([("category", .int(0))])),

    .chatClearHistory: Body(
      summary:
        "Deletes every message in a conversation, on every device on this account. NOT "
        + "reversible, and the confirmation is in the BODY on purpose: a query parameter "
        + "gets copied from one request to the next, and this is one typo away from emptying "
        + "a conversation nobody meant to touch.",
      properties: [
        Property(
          "confirm", .boolean,
          "Must be `true`. Anything else, the field absent included, is refused with the "
            + "reason.", required: true)
      ],
      example: .obj([("confirm", .bool(true))])),

  ]
}
