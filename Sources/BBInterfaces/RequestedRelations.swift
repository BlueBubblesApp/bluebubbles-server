//  RequestedRelations
//  The `with` parameter: which related objects a read should load.
//
//  One parser for every route that takes it, in either of the two shapes it arrives in: a
//  JSON array on the POST query routes, a comma-separated query string on the GETs. The
//  reference has one too (`parseWithQuery`, `api/http/api/v1/utils.ts`), and it accepts
//  both shapes from either place, trims each entry and lowercases it.
//
//  The spellings of the MESSAGE relations live here and nowhere else. The reference accepts
//  two names for each blob column (`attributedBody` and `attributed-body`, and so on), and
//  three routes each listed both by hand; a fourth spelling added to one of them would have
//  reached that route and not the other two. Which relations a route HONOURS is still the
//  route's decision, because it genuinely differs: `GET /message/:guid` reads no attachment
//  metadata and `GET /chat/:guid/message` reads no participants, in the reference as here.
//
//  **Matching is by SUBSTRING**, where the reference uses exact membership
//  (`arrayHasOne`). So `chat.participants` turns `chats` on here and does not there. That is
//  a decision, not an oversight: an extra field is tolerable because clients ignore what
//  they do not know, while matching exactly would REMOVE `chats` from a response that has
//  always carried it for a client asking only for `chat.participants`. See
//  `MessageInterface.Query.parse`.

import BBCore
import BBSerialization
import Foundation

public struct RequestedRelations: Sendable, Equatable {

  /// The names as given, trimmed and lowercased, with empty entries dropped.
  public let names: [String]

  public init(_ names: [String]) {
    self.names =
      names
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty }
  }

  /// From a body field: an array of strings, or one comma-separated string.
  ///
  /// Anything else reads as nothing asked for. Non-string array entries are skipped, as
  /// `parseWithQuery` skips them.
  public init(_ value: JSONValue?) {
    switch value {
    case .array(let entries)?: self.init(entries.compactMap(\.stringValue))
    case .string(let list)?: self.init(commaSeparated: list)
    default: self.init([String]())
    }
  }

  /// From a query parameter: `?with=chat,attachment`.
  public init(commaSeparated raw: String?) {
    self.init(raw.map { $0.split(separator: ",").map(String.init) } ?? [])
  }

  public var isEmpty: Bool { names.isEmpty }

  /// Whether any entry contains `relation`. Pass it lowercased.
  public func wants(_ relation: String) -> Bool {
    names.contains { $0.contains(relation) }
  }

  // MARK: - Message relations

  /// `chat`, `chats`, `chat.participants`, and anything else naming the chat.
  public var chats: Bool { wants("chat") }

  public var attachments: Bool { wants("attachment") }

  public var chatParticipants: Bool { wants("participant") }

  /// `attributedBody` or `attributed-body`, with or without a `message.` prefix: the chat
  /// route's reference spells it `message.attributedbody`, and a substring match takes both.
  public var attributedBody: Bool { wants("attributedbody") || wants("attributed-body") }

  public var messageSummaryInfo: Bool {
    wants("messagesummaryinfo") || wants("message-summary-info")
  }

  public var payloadData: Bool { wants("payloaddata") || wants("payload-data") }

  /// `attachment.metadata` or `attachments.metadata`: the reference's opt-in for reading
  /// each attachment off disk for its dimensions.
  public var attachmentMetadata: Bool {
    wants("attachment.metadata") || wants("attachments.metadata")
  }
}
