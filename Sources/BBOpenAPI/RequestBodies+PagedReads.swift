//  RequestBodies+PagedReads
//  The paged read routes' bodies: chats, handles and contacts, which are POST because the
//  reference made them POST, so their filters are bodies.
//
//  Its own file so the three paging shapes are read side by side. The declaration model, the
//  rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let pagedReadBodies: [HandlerID: Body] = [
    // MARK: The paged read routes
    //
    // POST rather than GET because the reference made them POST, so their inputs are bodies
    // and a client author has nowhere to look for them but here. The recorded fixtures cover
    // the paging fields and none of the filters, which is the half that decides what comes
    // back.

    .chatQuery: Body(
      summary:
        "Pages the conversation list. Every field is optional: an empty body answers with the "
        + "first 1000 chats. `metadata` carries `total` (chats matching the filter, not the "
        + "size of the table), `count`, `limit` and `offset`.",
      properties: [
        Property(
          "with", .array(of: .string),
          "Relations to load. `lastmessage` (or `last-message`) is the only one this route "
            + "reads: participants are ALWAYS loaded here, which is the opposite of "
            + "`GET /chat/{guid}`, where they are loaded only when asked for. A client that "
            + "reads an empty participant list as \"this chat is not real\" is the reason "
            + "that asymmetry is worth knowing."),
        Property(
          "guid", .string,
          "Scope the page to one conversation. `metadata.total` then counts what the filter "
            + "matched rather than the whole table."),
        Property("limit", .integer, "Page size, 1 to 1000 inclusive. Defaults to 1000."),
        Property("offset", .integer, "Chats to skip before the page. Defaults to 0."),
        Property(
          "sort", .string,
          "`lastmessage`, the only accepted value, orders by the most recent message. Asking "
            + "for the `lastmessage` relation and giving no sort selects it anyway, so the "
            + "two halves of a conversation list cannot disagree about the order."),
        Property(
          "includeArchived", .boolean,
          "Defaults to true. Send false to leave archived conversations out of both the page "
            + "and the total."),
      ],
      examples: [
        Example(
          "conversation-list",
          "A page of the conversation list.",
          "What a client builds its chat list from: the newest message on each conversation, "
            + "ordered by it. Page with `offset` until `metadata.count` is zero.",
          .obj([
            ("with", .array([.string("lastmessage")])),
            ("sort", .string("lastmessage")),
            ("limit", .int(100)),
            ("offset", .int(0)),
          ])),
        Example(
          "one-conversation",
          "One conversation, by its GUID.",
          "Scoped with `guid` rather than read through `GET /chat/{guid}`, because this route "
            + "loads participants without being asked and that one does not.",
          .obj([
            ("guid", .string("iMessage;-;+15551234567")),
            ("with", .array([.string("lastmessage")])),
          ])),
      ],
      required: false),

    .handleQuery: Body(
      summary:
        "Pages the handle table: the addresses this Mac has messaged or been messaged by. "
        + "Every field is optional. `metadata` carries `total` (handles matching `address`, "
        + "not the size of the table), `count`, `limit` and `offset`.",
      properties: [
        Property(
          "address", .string,
          "One address to look up, matched exactly. Applied to `metadata.total` as well as "
            + "to the page, so a client asking about one correspondent is not handed an "
            + "unfiltered page."),
        Property(
          "with", .array(of: .string),
          "Relations to load. Any entry containing `chat` loads the conversations the handle "
            + "is in, so `chat`, `chats` and `chat.participants` all select it."),
        Property("limit", .integer, "Page size, 1 to 1000 inclusive. Defaults to 100."),
        Property("offset", .integer, "Handles to skip before the page. Defaults to 0."),
      ],
      example: .obj([
        ("address", .string("+15551234567")),
        ("with", .array([.string("chat")])),
        ("limit", .int(100)),
        ("offset", .int(0)),
      ]),
      required: false),

    .contactQuery: Body(
      summary:
        "Looks up contacts by address, or pages the whole address book when `addresses` is "
        + "empty. Answers with the matching contacts and nothing else: there is no envelope "
        + "metadata on this route.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "Phone numbers or email addresses to resolve, normalised before matching. An empty "
            + "array or an absent field lists everything; a value that is not an array is "
            + "refused rather than read as empty, because an unfiltered page is not what a "
            + "client asking about one address wanted."),
        Property(
          "extraProperties", .array(of: .string),
          "Properties that cost extra work and are off by default. `avatar` is the one that "
            + "exists, and it base64-encodes each contact's photo into the response. A "
            + "comma-separated string is accepted in place of the array."),
        Property("limit", .integer, "Page size when listing. Defaults to 1000."),
        Property("offset", .integer, "Contacts to skip when listing. Defaults to 0."),
      ],
      examples: [
        Example(
          "resolve-addresses",
          "Names for the addresses in a chat.",
          "The request a client makes once per conversation it opens: hand it the "
            + "participants and it answers with whatever the address book knows about them.",
          .obj([
            (
              "addresses",
              .array([.string("+15551234567"), .string("someone@example.com")])
            )
          ])),
        Example(
          "whole-book-with-avatars",
          "A page of the address book, with photos.",
          "`avatar` is opt-in because it base64-encodes an image per contact; ask for it on "
            + "the page a client is about to display, not on a background sync.",
          .obj([
            ("addresses", .array([])),
            ("extraProperties", .array([.string("avatar")])),
            ("limit", .int(200)),
            ("offset", .int(0)),
          ])),
      ],
      required: false),

  ]
}
