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
    registry.register(.contactCreate) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      return .data(ContactInterface.serialize(try await interfaces.contact.create(values.raw)))
    }

    // One handler for two routes: `PUT /contact` takes the id in the body, `PUT
    // /contact/:id` in the path. Both ship, and clients use both.
    registry.register(.contactUpdate) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      guard let id = request.pathParameters["id"] ?? values["id"]?.stringValue else {
        throw BadRequest("`id` is required, in the path or the body")
      }
      return .data(
        ContactInterface.serialize(try await interfaces.contact.update(id: id, body: values.raw)))
    }

    registry.register(.contactDelete) { request in
      let interfaces = try await context.requireInterfaces()
      let body = try? request.jsonBody()
      guard let id = request.pathParameters["id"] ?? body?["id"]?.stringValue else {
        throw BadRequest("`id` is required, in the path or the body")
      }
      try await interfaces.contact.delete(id: id)
      return .data(nil)
    }

    registry.register(.contactFindByExternalID) { request in
      let externalID = try request.requirePathParameter("externalId")
      guard let record = try await context.contacts.contact(externalID: externalID) else {
        throw NotFound("no contact with external id \(externalID)")
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
      return .data(.object(["imported": .int(records.count)]))
    }
  }
}
