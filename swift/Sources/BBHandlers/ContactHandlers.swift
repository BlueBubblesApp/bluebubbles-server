//  ContactHandlers
//  Controllers for the contact write path and vCard import.

import BBContacts
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum ContactHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some ContactIndexProviding & InterfaceProviding
  ) {
    // The three write routes are BATCH routes, and answer with an ARRAY.
    //
    // All three took a single record and answered with a single object, which is neither
    // shape a client parses. The reference wraps a bare object into a one-element array,
    // commits every entry it can, and reports the rest in `metadata.errors` rather than
    // failing the request — so one malformed contact in a sync of a hundred costs one, not
    // a hundred. See `ContactInterface`'s batch section.
    registry.register(.contactCreate) { request in
      let interfaces = try await context.requireInterfaces()
      let outcome = try await interfaces.contact.create(batch: try request.values().raw)
      return Self.result(
        outcome.map { ContactInterface.serialize($0) },
        emptyMessage: "No contacts were created!"
      )
    }

    // One handler for two routes: `PUT /contact` takes a batch with an id per entry, `PUT
    // /contact/:id` a single body under the path's id. Both ship, and clients use both.
    registry.register(.contactUpdate) { request in
      let interfaces = try await context.requireInterfaces()
      let outcome = try await interfaces.contact.update(
        batch: try request.values().raw, id: request.pathParameters["id"]
      )
      return Self.result(
        outcome.map { ContactInterface.serialize($0) },
        emptyMessage: "No contacts were updated!"
      )
    }

    // `DELETE /contact/:id` answers with a message and NO data; `DELETE /contact` answers
    // with the ids it removed and a count in the message. Two different envelopes on one
    // handler, because that is what the reference sends and what clients read.
    registry.register(.contactDelete) { request in
      let interfaces = try await context.requireInterfaces()
      if let id = request.pathParameters["id"] {
        try await interfaces.contact.delete(id: id)
        return .data(nil, message: "Contact with ID: \(id) deleted successfully")
      }

      let outcome = try await interfaces.contact.delete(batch: try request.values().raw)
      return .data(
        .array(outcome.succeeded.map { .object(["id": .string($0)]) }),
        metadata: Self.errorMetadata(outcome.failures),
        message: "\(outcome.succeeded.count) contacts deleted successfully"
      )
    }

    // 200 with `data: null` for a contact that is not there — NOT a 404. The reference
    // answers `new Success(ctx, { data: null })`, and a client that treats 404 as an error
    // would report a failure for a lookup that worked and found nothing.
    registry.register(.contactFindByExternalID) { request in
      let externalID = try request.requirePathParameter("externalId")
      guard let record = try await context.contacts.contact(externalID: externalID) else {
        return .data(.null)
      }
      return .data(ContactInterface.serialize(record))
    }

    registry.register(.contactImportVCF) { request in
      guard let body = request.body, !body.isEmpty else {
        throw BadRequest("the request body is empty")
      }
      // The raw file, not JSON. A vCard export is not valid JSON and clients POST it
      // with `text/vcard`, so parsing the body as JSON first would reject every real
      // request.
      guard let text = String(data: body, encoding: .utf8) else {
        throw BadRequest("the vCard file is not valid UTF-8")
      }

      let cards = VCard.parse(text)
      guard !cards.isEmpty else {
        throw BadRequest("no usable contacts in that file")
      }

      let records = cards.map { card in
        ContactRecord(
          id: UUID().uuidString,
          source: .local,
          firstName: card.firstName,
          lastName: card.lastName,
          displayName: card.displayName,
          nickname: card.nickname,
          birthday: card.birthday,
          externalID: card.externalID,
          phoneNumbers: card.phoneNumbers,
          emailAddresses: card.emailAddresses
        )
      }
      try await context.contacts.upsert(records)
      // The imported contacts themselves, and a counted message. `{"imported": n}` was
      // this server's own invention.
      return .data(
        .array(records.map { ContactInterface.serialize($0) }),
        message: records.isEmpty
          ? "No contacts were imported. The VCF file may be empty or invalid."
          : "\(records.count) contacts imported successfully"
      )
    }
  }

  /// The envelope a batch write produces: the records it wrote, the entries it could not,
  /// and the reference's own "nothing happened" message when there are none.
  private static func result(
    _ outcome: ContactInterface.BatchOutcome<JSONValue>, emptyMessage: String
  ) -> RouteResult {
    .data(
      .array(outcome.succeeded),
      metadata: errorMetadata(outcome.failures),
      message: outcome.succeeded.isEmpty ? emptyMessage : nil
    )
  }

  /// `metadata.errors`, or nothing at all. Absent rather than empty when every entry took —
  /// the reference adds the key only when there is something in it, and an empty array reads
  /// to a client as "the server checked and found none", which is a different claim.
  private static func errorMetadata<Value>(
    _ failures: [ContactInterface.BatchOutcome<Value>.Failure]
  ) -> JSONValue? {
    guard !failures.isEmpty else { return nil }
    return .object([
      "errors": .array(
        failures.map { .object(["entry": $0.entry, "error": .string($0.message)]) })
    ])
  }
}
