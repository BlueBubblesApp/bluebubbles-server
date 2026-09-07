//  FaceTimeLinkLedger
//  The links THIS SERVER minted, so cleanup can never touch the user's own.
//
//  WHY A LEDGER AND NOT A FLAG ON THE LINK. Invalidation needs to distinguish a link the
//  server created from one the user made in FaceTime.app, and TelephonyUtilities cannot:
//  `TUConversationLink.locallyCreated` is 1 for BOTH — it means "created on this Mac", not
//  "created by us". There is no other marker. So the only safe basis for deleting anything is
//  a record we keep ourselves, and cleanup acts on this list and nothing else.
//
//  Deleting a person's own FaceTime link is unrecoverable and invisible until they try to use
//  it, which is why the safety here is structural: a URL that was never recorded is never a
//  candidate, whatever else is going on.
//
//  Stored as JSON in the support directory rather than in the app database: it is a handful of
//  short-lived rows, it must survive a restart, and it must be readable by a human trying to
//  work out what the server deleted.

import BBPrivateAPIContract
import Foundation
import Logging

public actor FaceTimeLinkLedger {

  public struct Entry: Codable, Sendable, Equatable {
    public let url: String
    public let groupUUID: String?
    public let createdAt: Date

    public init(url: String, groupUUID: String?, createdAt: Date = Date()) {
      self.url = url
      self.groupUUID = groupUUID
      self.createdAt = createdAt
    }
  }

  private let path: String
  private let logger = Logger(label: "bluebubbles.facetime.ledger")
  private var entries: [Entry]?

  public static var defaultPath: String {
    SocketLocation.supportDirectory + "/facetime-links.json"
  }

  public init(path: String = FaceTimeLinkLedger.defaultPath) {
    self.path = path
  }

  /// Records a link the server just minted.
  ///
  /// Best effort by design: failing to record a link must never fail the request that
  /// created it. The cost of a missed record is a stray link, which is recoverable; the cost
  /// of failing the request is a user who cannot start a call.
  public func record(url: String, groupUUID: String?) async {
    guard !url.isEmpty else { return }
    var current = await load()
    guard !current.contains(where: { $0.url == url }) else { return }
    current.append(Entry(url: url, groupUUID: groupUUID))
    await save(current)
  }

  public func all() async -> [Entry] {
    await load()
  }

  /// Entries older than `age`. The TTL sweep's candidates.
  public func expired(olderThan age: TimeInterval, now: Date = Date()) async -> [Entry] {
    await load().filter { now.timeIntervalSince($0.createdAt) > age }
  }

  /// Forgets these URLs — called once they have actually been invalidated, so a link that
  /// could NOT be invalidated stays on the list and is retried next time.
  public func forget(urls: [String]) async {
    guard !urls.isEmpty else { return }
    let removing = Set(urls)
    await save(await load().filter { !removing.contains($0.url) })
  }

  // MARK: - Storage

  private func load() async -> [Entry] {
    if let entries { return entries }
    guard let data = FileManager.default.contents(atPath: path) else {
      entries = []
      return []
    }
    do {
      let decoded = try JSONDecoder().decode([Entry].self, from: data)
      entries = decoded
      return decoded
    } catch {
      // A corrupt ledger must not wedge the server, and it must not be treated as "no
      // links exist" silently — that would look like a clean slate while strays pile up.
      logger.warning(
        "The FaceTime link ledger could not be read",
        metadata: [
          "path": .string(path), "error": .string(String(describing: error)),
        ])
      entries = []
      return []
    }
  }

  private func save(_ list: [Entry]) async {
    entries = list
    do {
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(list).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
      logger.warning(
        "The FaceTime link ledger could not be written",
        metadata: [
          "path": .string(path), "error": .string(String(describing: error)),
        ])
    }
  }
}
