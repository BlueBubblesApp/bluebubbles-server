//  RequestBodies+Scheduling
//  The bodies of the two scheduling surfaces: Send Later (Messages' own, on the Private API)
//  and this server's scheduled messages.
//
//  Its own file so the two are read together and told apart. The declaration model, the
//  rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let schedulingBodies: [HandlerID: Body] = [
    // MARK: Send Later

    .messageSendLater: Body(
      summary: "Schedules a message with Apple, so it sends whether or not this Mac is awake.",
      properties: [
        chatGUID(),
        Property("message", .string, "The text to send.", required: true),
        Property(
          "scheduledFor", .integer,
          "When to deliver it, in epoch MILLISECONDS. Must be in the future.", required: true),
        Property("tempGuid", .string, "Echoed back on the sent message."),
        Property("subject", .string, "Subject line."),
        Property("effectId", .string, "A send effect."),
        Property("selectedMessageGuid", .string, "The message this one replies to."),
        Property("partIndex", .integer, "Which part of the replied-to message."),
        Property(
          "ddScan", .boolean,
          "Scan the text for links before it is scheduled, as on `message/text`."),
        textFormatting,
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("message", .string("Happy birthday!")),
        ("scheduledFor", .int(1_788_440_082_220)),
      ])),

    .messageReschedule: Body(
      summary: "Changes a pending message's text, its delivery time, or both.",
      properties: [
        chatGUID("The conversation the scheduled message is in."),
        Property("message", .string, "Replacement text. Leaves the time alone if sent alone."),
        Property(
          "scheduledFor", .integer,
          "A new delivery time, epoch MILLISECONDS. Leaves the text alone if sent alone."),
        Property("partIndex", .integer, "Which part to rewrite. Defaults to 0."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("message", .string("Actually, happy anniversary!")),
        ("scheduledFor", .int(1_788_443_682_220)),
      ])),

    .messageSendScheduledNow: Body(
      summary: "Delivers a pending message immediately.",
      properties: [chatGUID("The conversation the scheduled message is in.")],
      example: .obj([("chatGuid", .string("iMessage;-;+15551234567"))])),

    .messageCancelScheduled: Body(
      summary: "Cancels a pending message. Its row is deleted, not marked cancelled.",
      properties: [chatGUID("The conversation the scheduled message is in.")],
      example: .obj([("chatGuid", .string("iMessage;-;+15551234567"))])),

    // MARK: Scheduled messages
    //
    // This server's own scheduler, which holds the message and sends it when the time comes.
    // Not to be confused with Send Later above, which hands the message to Apple.

    .scheduleCreate: Body(
      summary:
        "Schedules a message for this server to send later. The Mac has to be awake and the "
        + "server running when the time comes — hand the message to Apple with "
        + "`POST message/send-later` instead if it has to go out regardless. All four fields "
        + "are required, `schedule` included: a one-off is `{\"type\": \"once\"}`.",
      properties: [
        Property(
          "type", .string,
          "What the entry does. `send-message` is the only kind that exists.", required: true),
        Property(
          "payload",
          .object(properties: [
            Property("chatGuid", .string, "The conversation to send to.", required: true),
            Property("message", .string, "The text to send.", required: true),
            Property(
              "method", .string,
              "`apple-script` or `private-api`, chosen when the message is scheduled rather "
                + "than when it is sent.", required: true),
          ]),
          "What to send when the time comes. All three fields are required, and an empty "
            + "string counts as missing.", required: true),
        Property(
          "scheduledFor", .integer,
          "When to send it, epoch MILLISECONDS. A time in the past is refused rather than "
            + "sent immediately: a client with a wrong clock would otherwise fire off a "
            + "message meant for next week, and there is no recalling it.", required: true),
        Property(
          "schedule",
          .object(properties: [
            Property(
              "type", .string, "`once` or `recurring`.", required: true),
            Property(
              "interval", .integer,
              "How many `intervalType` units between sends. At least 1. Required for "
                + "`recurring`."),
            Property(
              "intervalType", .string,
              "One of `hourly`, `daily`, `weekly`, `monthly`, `yearly`. Required for "
                + "`recurring`, and a value outside that list is refused — a typo used to be "
                + "stored, send once, and go on reporting itself as recurring forever."),
          ]),
          "How often it repeats. Required even for a one-off.", required: true),
      ],
      examples: [
        Example(
          "one-off",
          "One message, at one time.",
          "`schedule` is still required; `{\"type\": \"once\"}` is what a one-off sends, and "
            + "is what the app sends from its conversation view.",
          .obj([
            ("type", .string("send-message")),
            (
              "payload",
              .obj([
                ("chatGuid", .string("iMessage;-;+15551234567")),
                ("message", .string("Happy birthday!")),
                ("method", .string("private-api")),
              ])
            ),
            ("scheduledFor", .int(1_788_440_082_220)),
            ("schedule", .obj([("type", .string("once"))])),
          ])),
        Example(
          "every-week",
          "A message that repeats.",
          "The series counts from `scheduledFor`, and rescheduling moves the whole series to "
            + "the new date rather than keeping it on the original one.",
          .obj([
            ("type", .string("send-message")),
            (
              "payload",
              .obj([
                ("chatGuid", .string("iMessage;+;chat000000000000000001")),
                ("message", .string("Standup in 10")),
                ("method", .string("private-api")),
              ])
            ),
            ("scheduledFor", .int(1_788_440_082_220)),
            (
              "schedule",
              .obj([
                ("type", .string("recurring")), ("interval", .int(1)),
                ("intervalType", .string("weekly")),
              ])
            ),
          ])),
      ]),

    .scheduleUpdate: Body(
      summary:
        "Reschedules a PENDING message. One already sent, or failed, is refused rather than "
        + "silently accepted, because a client showing a future send that will never happen "
        + "is worse than an error. Send the whole entry: the same four fields the create "
        + "takes, with the changes in them.",
      properties: [
        Property(
          "type", .string, "`send-message`, as on the create.", required: true),
        Property(
          "payload",
          .object(properties: [
            Property("chatGuid", .string, "The conversation to send to.", required: true),
            Property("message", .string, "The text to send.", required: true),
            Property("method", .string, "`apple-script` or `private-api`.", required: true),
          ]),
          "The replacement payload, validated exactly as the create's is.", required: true),
        Property(
          "scheduledFor", .integer,
          "The new send time, epoch MILLISECONDS, and it must be in the future. Moving it "
            + "restarts a recurring series from the new date.", required: true),
        Property(
          "schedule",
          .object(properties: [
            Property("type", .string, "`once` or `recurring`.", required: true),
            Property("interval", .integer, "Units between sends. At least 1."),
            Property(
              "intervalType", .string,
              "One of `hourly`, `daily`, `weekly`, `monthly`, `yearly`."),
          ]),
          "The replacement recurrence.", required: true),
      ],
      example: .obj([
        ("type", .string("send-message")),
        (
          "payload",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            ("message", .string("Actually, happy anniversary!")),
            ("method", .string("private-api")),
          ])
        ),
        ("scheduledFor", .int(1_788_443_682_220)),
        ("schedule", .obj([("type", .string("once"))])),
      ])),

  ]
}
