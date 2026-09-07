//  Corpus
//  The requests the side-by-side run drives against both servers.
//
//  READ-ONLY, deliberately and without exception. This runs against a real Mac with real
//  messages, and a corpus that sent anything would send it twice — once per server — to real
//  people. Every entry below is a GET or a query POST that reads.
//
//  See `docs/TESTING.md`, "Side-by-side beta".

import Foundation

public struct CorpusRequest: Sendable, Identifiable {
  public enum Method: String, Sendable {
    case get = "GET"
    case post = "POST"
  }

  public let id: String
  public let method: Method
  public let path: String
  public let query: [String: String]
  /// JSON body, for the query endpoints.
  public let body: String?
  /// Skipped unless the runner is given a chat GUID to substitute.
  public let needsChatGUID: Bool

  public init(
    id: String,
    method: Method = .get,
    path: String,
    query: [String: String] = [:],
    body: String? = nil,
    needsChatGUID: Bool = false
  ) {
    self.id = id
    self.method = method
    self.path = path
    self.query = query
    self.body = body
    self.needsChatGUID = needsChatGUID
  }
}

public enum Corpus {

  /// The default read-only corpus.
  ///
  /// Limits are small on purpose. The comparison is of SHAPE, not of how many rows each
  /// server can return, and a thousand-message diff is unreadable when it fails — which is
  /// the moment the output matters most.
  public static let readOnly: [CorpusRequest] = [
    .init(id: "ping", path: "/api/v1/ping"),
    .init(id: "server.info", path: "/api/v1/server/info"),
    .init(id: "server.statTotals", path: "/api/v1/server/statistics/totals"),
    .init(id: "server.statMedia", path: "/api/v1/server/statistics/media"),
    .init(id: "server.alerts", path: "/api/v1/server/alert"),

    .init(id: "message.count", path: "/api/v1/message/count"),
    .init(id: "message.sentCount", path: "/api/v1/message/count/me"),
    .init(
      id: "message.query",
      method: .post, path: "/api/v1/message/query",
      body: #"{"limit":5,"offset":0,"with":["chat","attachment","handle"]}"#
    ),
    .init(
      id: "message.query.sorted",
      method: .post, path: "/api/v1/message/query",
      body: #"{"limit":5,"offset":0,"sort":"ASC"}"#
    ),

    .init(id: "chat.count", path: "/api/v1/chat/count"),
    .init(
      id: "chat.query",
      method: .post, path: "/api/v1/chat/query",
      body: #"{"limit":5,"offset":0,"with":["participants"]}"#
    ),

    .init(id: "handle.count", path: "/api/v1/handle/count"),
    .init(
      id: "handle.query",
      method: .post, path: "/api/v1/handle/query",
      body: #"{"limit":5,"offset":0}"#
    ),

    .init(id: "attachment.count", path: "/api/v1/attachment/count"),
    .init(id: "contact.list", path: "/api/v1/contact"),

    .init(id: "backup.theme", path: "/api/v1/backup/theme"),
    .init(id: "backup.settings", path: "/api/v1/backup/settings"),
    .init(id: "schedule.list", path: "/api/v1/message/schedule"),
    .init(id: "findmy.devices", path: "/api/v1/icloud/findmy/devices"),

    // Per-chat reads. Skipped unless a GUID is supplied, because there is no chat GUID
    // that is safe to hardcode — every real one is somebody's conversation.
    .init(id: "chat.find", path: "/api/v1/chat/{chatGuid}", needsChatGUID: true),
    .init(
      id: "chat.messages",
      path: "/api/v1/chat/{chatGuid}/message",
      query: ["limit": "5"],
      needsChatGUID: true
    ),
    .init(
      id: "message.count.scoped",
      path: "/api/v1/message/count",
      query: ["chatGuid": "{chatGuid}"],
      needsChatGUID: true
    ),
  ]

  /// Substitutes the chat GUID, or drops the entries that need one.
  public static func resolved(
    _ requests: [CorpusRequest] = readOnly,
    chatGUID: String?
  ) -> [CorpusRequest] {
    requests.compactMap { request in
      guard request.needsChatGUID else { return request }
      guard let chatGUID else { return nil }

      // Percent-encoded here rather than at the call site: a chat GUID is
      // `iMessage;-;+15555550101`, and the semicolons and plus would otherwise be
      // read as URL syntax by one server and as data by the other — producing a
      // "difference" that is entirely the harness's fault.
      let encoded =
        chatGUID.addingPercentEncoding(
          withAllowedCharacters: .alphanumerics
        ) ?? chatGUID

      return CorpusRequest(
        id: request.id,
        method: request.method,
        path: request.path.replacingOccurrences(of: "{chatGuid}", with: encoded),
        query: request.query.mapValues {
          $0.replacingOccurrences(of: "{chatGuid}", with: chatGUID)
        },
        body: request.body,
        needsChatGUID: false
      )
    }
  }
}
