//  RequestBodies+Server
//  The server administration bodies: alerts, theme and settings backups, webhooks, FCM
//  device registration and the iCloud alias.
//
//  Its own file so a client author configuring the server opens these and not the messaging
//  routes. The declaration model, the rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let serverBodies: [HandlerID: Body] = [
    // MARK: Server administration

    .serverMarkAlertRead: Body(
      summary:
        "Marks server alerts read. An empty list is a 400, not \"mark everything\": the two "
        + "differ by one parse failure, and the wrong one of them is unrecoverable.",
      properties: [
        Property(
          "ids", .array(of: .integer),
          "The alerts to mark, as returned by `GET server/alert`. Numbers and strings are "
            + "both read, because clients send both.", required: true),
        Property(
          "id", .integer,
          "A single alert, accepted alongside `ids` and appended to it."),
      ],
      example: .obj([("ids", .array([.int(6), .int(7)]))])),

    .serverMarkAlertReadV2: Body(
      summary:
        "Marks server alerts read. The same request as the v1 route, on the v2 prefix, so a "
        + "client that started a flow on v2 never has to drop back to finish it.",
      properties: [
        Property(
          "ids", .array(of: .integer),
          "The alerts to mark, as returned by `GET server/alert`. Numbers and strings are "
            + "both read.", required: true),
        Property("id", .integer, "A single alert, appended to `ids`."),
      ],
      example: .obj([("ids", .array([.int(6), .int(7)]))])),

    .backupCreateTheme: Body(
      summary:
        "Stores a named theme for clients to sync. THE WHOLE BODY IS STORED, not just "
        + "`data`: whatever a client puts here is what `GET backup/theme` hands back, so the "
        + "document's shape is the client's to decide. Posting an existing name replaces it.",
      properties: [
        Property(
          "name", .string,
          "What the backup is called, 3 to 50 characters. The key a client reads it back by, "
            + "and the key a replace matches on.", required: true),
        Property(
          "data", .anything,
          "The theme itself, in whatever shape the client uses. Required, and not inspected.",
          required: true),
      ],
      example: .obj([
        ("name", .string("Midnight")),
        (
          "data",
          .obj([
            ("name", .string("Midnight")),
            ("primaryColor", .string("#5B8DEF")),
            ("surfaceColor", .string("#101114")),
          ])
        ),
      ])),

    .backupDeleteTheme: Body(
      summary:
        "Deletes one named theme. The name is REQUIRED: a nameless delete used to remove "
        + "every theme the user had, and the reference has never allowed one.",
      properties: [
        Property(
          "name", .string,
          "The theme to delete, 3 to 50 characters. Accepted as a query parameter too, for "
            + "clients whose HTTP layer will not put a body on a DELETE.", required: true)
      ],
      example: .obj([("name", .string("Midnight"))])),

    .backupCreateSettings: Body(
      summary:
        "Stores a named client settings backup. As with themes, THE WHOLE BODY IS STORED and "
        + "handed back unchanged, so the document is the client's own; posting an existing "
        + "name replaces it.",
      properties: [
        Property(
          "name", .string,
          "What the backup is called, 3 to 50 characters.", required: true),
        Property(
          "data", .anything,
          "The settings themselves, in whatever shape the client uses. Required, and not "
            + "inspected.", required: true),
      ],
      example: .obj([
        ("name", .string("Pixel 9")),
        (
          "data",
          .obj([
            ("name", .string("Pixel 9")),
            ("autoStart", .bool(true)),
            ("sendDelay", .int(0)),
          ])
        ),
      ])),

    .backupDeleteSettings: Body(
      summary:
        "Deletes one named settings backup. The name is REQUIRED, for the same reason the "
        + "theme delete requires one.",
      properties: [
        Property(
          "name", .string,
          "The backup to delete, 3 to 50 characters. Accepted as a query parameter too.",
          required: true)
      ],
      example: .obj([("name", .string("Pixel 9"))])),

    .webhookCreate: Body(
      summary:
        "Registers a URL this server POSTs events to. An event name outside the list is "
        + "REFUSED rather than stored: a typo used to create a webhook that matched nothing, "
        + "fired never, and said so nowhere.",
      properties: [
        Property(
          "url", .string,
          "Where to POST. Each delivery is a JSON body of `{\"type\": …, \"data\": …}`.",
          required: true),
        Property(
          "events", .array(of: .string),
          "The events to subscribe to, or `[\"*\"]` for all of them. Each name must be one "
            + "the server emits: `new-message`, `updated-message`, `message-send-error`, "
            + "`group-name-change`, `group-icon-changed`, `group-icon-removed`, "
            + "`participant-removed`, `participant-added`, `participant-left`, "
            + "`chat-read-status-changed`, `typing-indicator`, `scheduled-message-error`, "
            + "`server-update`, `new-server`, `new-findmy-location`, `hello-world`, "
            + "`incoming-facetime`, `ft-call-status-changed`, `imessage-alias-removed`, and "
            + "the six theme and settings backup events.", required: true),
        Property(
          "followRedirects", .boolean,
          "Follow a 3xx from the target. Defaults to false. `follow_redirects` is read too."),
      ],
      example: .obj([
        ("url", .string("https://example.com/bluebubbles")),
        (
          "events",
          .array([
            .string("new-message"), .string("updated-message"),
            .string("message-send-error"),
          ])
        ),
        ("followRedirects", .bool(false)),
      ])),

    .webhookUpdate: Body(
      summary:
        "Changes a registered webhook. Every field is optional and ABSENT MEANS LEAVE IT: a "
        + "body carrying only `events` must not blank the URL, and a client re-registering "
        + "after a reinstall must not disarm a switch the operator set.",
      properties: [
        Property("url", .string, "A new destination. Absent leaves the current one."),
        Property(
          "events", .array(of: .string),
          "A new subscription list, replacing the old one. Absent leaves it; an empty array "
            + "is a real value and subscribes to nothing. Names are validated exactly as on "
            + "the create."),
        Property(
          "followRedirects", .boolean,
          "Change the redirect policy. Absent leaves it. `follow_redirects` is read too."),
      ],
      example: .obj([
        ("url", .string("https://example.com/bluebubbles/v2")),
        ("events", .array([.string("*")])),
      ]),
      required: false),

    .fcmRegisterDevice: Body(
      summary:
        "Registers a device for push notifications, or refreshes the token of one already "
        + "registered: the row is keyed by the token, so re-posting updates the name and the "
        + "last-seen time rather than adding a second entry.",
      properties: [
        Property(
          "name", .string,
          "What to call the device in the server's device list. Required: the handler would "
            + "fall back to `Unknown Device`, but the validation layer refuses a request "
            + "without it, so nothing can reach that fallback.", required: true),
        Property(
          "identifier", .string,
          "The FCM registration token. `token` is accepted as an alias; send one.",
          required: true),
        Property(
          "token", .string,
          "The same token under the other name some clients send. Either is read."),
      ],
      example: .obj([
        ("name", .string("Pixel 9")),
        ("identifier", .string("fcm-registration-token-goes-here")),
      ])),

    .icloudChangeAlias: Body(
      summary:
        "Changes which of this Apple Account's addresses outgoing messages are sent from. "
        + "Checked against the account's own alias list first: IMCore accepts an address "
        + "that is not on it, keeps sending from the old one, and reports nothing.",
      properties: [
        Property(
          "alias", .string,
          "The address to send from. Must be one that `GET icloud/account` reports: its "
            + "`aliases` and `vetted_aliases` are arrays of OBJECTS, and the value to send "
            + "is an entry's `Alias`.", required: true)
      ],
      example: .obj([("alias", .string("someone@example.com"))])),

  ]
}
