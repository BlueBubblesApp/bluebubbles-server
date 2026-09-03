//  PollPayload
//  What is inside a poll's `payload_data`, and the JSON it carries.
//
//  A poll is an iMessage app message: `payload_data` is an `NSKeyedArchiver` graph of the
//  `MSMessage` the Polls extension sent, whose `URL` is a `data:` URL of base64 JSON. This
//  file walks the archive to that URL and to the `MSSession` UUID beside it, and decodes the
//  two JSON shapes (poll and vote). Everything here was read from real threads on macOS
//  26.5.2 — `docs/POLLS.md` § 3 is the reference and this is its implementation.
//
//  Unarchived with `NSKeyedUnarchiver` and a placeholder for the classes that exist only
//  inside Messages.app (`MSMessageTemplateLayout`), which a secure unarchive would refuse
//  outright. The values read are Foundation's own, so nothing is lost by the substitution.

import Foundation

public enum PollPayload {

  /// The `MSMessage` fields a poll or vote archive carries that this server reads.
  public struct Envelope: Equatable, Sendable {
    /// The `data:` URL's decoded JSON body.
    public let json: Data
    /// The `MSSession` identifier, upper-case UUID string.
    public let sessionID: String?
  }

  /// The poll as its creator (or last editor) sent it.
  public struct Definition: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
      public var optionIdentifier: String
      public var text: String
      public var attributedText: String?
      public var canBeEdited: Bool?
      public var creatorHandle: String?
    }
    public struct Item: Codable, Equatable, Sendable {
      public var title: String?
      public var creatorHandle: String?
      public var orderedPollOptions: [Option]
    }
    public var version: Int
    public var item: Item
  }

  /// One participant's complete selection.
  public struct Votes: Codable, Equatable, Sendable {
    public struct Vote: Codable, Equatable, Sendable {
      public var participantHandle: String?
      public var voteOptionIdentifier: String
    }
    public struct Item: Codable, Equatable, Sendable {
      public var votes: [Vote]
    }
    public var version: Int
    public var item: Item
  }

  /// Pulls the JSON and session out of an archive. Nil when the blob is not one of ours.
  ///
  /// The archive itself is every iMessage app's — see `AppMessagePayload`, which does the
  /// unarchiving. What is specific to Polls is that its `URL` body is base64 JSON.
  public static func envelope(from data: Data?) -> Envelope? {
    guard let app = AppMessagePayload.envelope(from: data), let url = app.url,
      let json = jsonBody(ofDataURL: url)
    else { return nil }
    return Envelope(json: json, sessionID: app.sessionID)
  }

  /// The base64 body of a `data:,…` URL, with the query Messages appends (`?src=p&c=3`)
  /// stripped — it is not part of the base64 and breaks the decode if left on.
  static func jsonBody(ofDataURL url: String) -> Data? {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
    var body = String(url[url.index(after: comma)...])
    if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }
    body = body.removingPercentEncoding ?? body
    let padding = (4 - body.count % 4) % 4
    return Data(base64Encoded: body + String(repeating: "=", count: padding))
  }

}

/// Stands in for any archived class this process cannot instantiate. It decodes nothing
/// and keeps nothing; the top-level dictionary still comes back with the keys we read.
