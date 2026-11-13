//  RequestBodies+Contacts
//  The contact write routes' bodies, which are batch routes whose bodies are arrays.
//
//  Its own file so the one place `isBatch` is true is read on its own. The declaration
//  model, the rules and `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// Merged into `byHandler`.
  static let contactBodies: [HandlerID: Body] = [
    // MARK: Contacts
    //
    // THE THREE WRITE ROUTES TAKE AN ARRAY, and that is the fact a client author most needs:
    // they commit every entry they can and report the rest in `metadata.errors` rather than
    // failing the request, so one malformed contact in a sync of a hundred costs one.

    .contactCreate: Body(
      summary:
        "Creates contacts in the server's own address book — not in the Mac's. A BATCH: send "
        + "an array, and each entry is committed or reported in `metadata.errors` "
        + "independently. A bare object is accepted and treated as a one-entry batch. An "
        + "entry needs at least one of `firstName`, `lastName` or `displayName`, and at "
        + "least one phone number or email address.",
      properties: [
        Property("firstName", .string, "Given name."),
        Property("lastName", .string, "Family name."),
        Property(
          "displayName", .string,
          "The name to show. Sent on its own where a contact has no separable parts, such as "
            + "a business."),
        Property("nickname", .string, "What the user calls this person."),
        Property("birthday", .string, "Stored and handed back verbatim; no format is imposed."),
        Property(
          "phoneNumbers", .array(of: .string),
          "Phone numbers, as strings. An array of `{\"address\": …}` objects is read too, "
            + "which is the shape a contact read back from this API has."),
        Property(
          "emails", .array(of: .string),
          "Email addresses. `emailAddresses` is accepted under the same rules and the two "
            + "are merged, so a client round-tripping a contact does not lose either."),
        Property(
          "externalId", .string,
          "The id this contact has in the client's own store, so a later sync can find it "
            + "again through `GET contact/external/{externalId}`. `externalID` is accepted "
            + "as well."),
      ],
      example: .array([
        .obj([
          ("firstName", .string("Sam")),
          ("lastName", .string("Rivera")),
          ("displayName", .string("Sam Rivera")),
          ("phoneNumbers", .array([.string("+15551234567")])),
          ("emails", .array([.string("someone@example.com")])),
          ("externalId", .string("contacts-store-4182")),
        ]),
        .obj([
          ("displayName", .string("Corner Bakery")),
          ("phoneNumbers", .array([.string("+15557654321")])),
        ]),
      ]),
      batch: true),

    .contactUpdate: Body(
      summary:
        "Replaces contacts the server holds. Two routes share this: `PUT /contact` takes an "
        + "array with an `id` per entry, and `PUT /contact/{id}` takes one entry under the "
        + "path's id. The entry REPLACES the stored contact, so send the whole record rather "
        + "than the fields that changed. An id that names no contact is a 400 quoting it.",
      properties: [
        Property(
          "id", .string,
          "The contact to replace, as returned by a read. Required on `PUT /contact`, where "
            + "there is no path to carry it; ignored on `PUT /contact/{id}`. A numeric id is "
            + "accepted as a number."),
        Property("firstName", .string, "Given name."),
        Property("lastName", .string, "Family name."),
        Property("displayName", .string, "The name to show."),
        Property("nickname", .string, "What the user calls this person."),
        Property("birthday", .string, "Stored and handed back verbatim."),
        Property(
          "phoneNumbers", .array(of: .string),
          "The complete set of phone numbers after the update, not an addition to it."),
        Property(
          "emails", .array(of: .string),
          "The complete set of email addresses after the update. `emailAddresses` is read too."),
        Property("externalId", .string, "The client's own id for this contact."),
      ],
      example: .array([
        .obj([
          ("id", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13")),
          ("firstName", .string("Sam")),
          ("lastName", .string("Rivera")),
          ("displayName", .string("Sam Rivera")),
          ("phoneNumbers", .array([.string("+15551234567"), .string("+15557654321")])),
          ("emails", .array([.string("someone@example.com")])),
        ])
      ]),
      batch: true),

    .contactDelete: Body(
      summary:
        "Deletes contacts from the server's address book. `DELETE /contact` takes an array "
        + "and answers with the ids it removed; `DELETE /contact/{id}` takes no body at all "
        + "and answers with a message. An entry may be a bare id — a string or a number — "
        + "instead of an object.",
      properties: [
        Property(
          "id", .string,
          "The contact to delete. An id that names no contact is reported in "
            + "`metadata.errors` and the rest of the batch still commits.", required: true)
      ],
      example: .array([
        .obj([("id", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13"))]),
        .obj([("id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38"))]),
      ]),
      batch: true),

  ]
}
