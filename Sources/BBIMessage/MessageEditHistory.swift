//  MessageEditHistory
//  The earlier versions of an edited message, and which parts were unsent.
//
//  `message_summary_info` is a binary plist Messages writes when a message is edited or
//  unsent. `ec` ("edited content") maps a part index to the revisions of that part, each a
//  typedstream of the attributed string as it was (`t`) and when it was replaced (`d`, in
//  seconds since 2001). `rp` lists the parts that were retracted. The wire serializer
//  publishes the whole plist decoded and renamed (`PropertyListWire`); this is the typed
//  reading of the two things a transcript needs, with the typedstreams turned into text.
//
//  Measured shapes are in `MessageSummaryInfoWireTests`: `d` is a plist real, and the
//  revisions include the CURRENT text as the last entry, so a reader wanting "what it said
//  before" drops the final one.

import BBCore
import Foundation

public enum MessageEditHistory {

  public struct Revision: Equatable, Sendable {
    public let date: Date?
    public let text: String

    public init(date: Date?, text: String) {
      self.date = date
      self.text = text
    }
  }

  public struct History: Equatable, Sendable {
    /// Revisions per part index, oldest first, the last being the text as it stands.
    public let revisions: [Int: [Revision]]
    /// Parts that were unsent.
    public let retractedParts: [Int]

    public init(revisions: [Int: [Revision]], retractedParts: [Int]) {
      self.revisions = revisions
      self.retractedParts = retractedParts
    }

    /// Every revision that was replaced, across parts, oldest first.
    public var earlierVersions: [Revision] {
      revisions.keys.sorted().flatMap { part -> [Revision] in
        let all = revisions[part] ?? []
        return Array(all.dropLast())
      }
    }

    public var isEmpty: Bool { revisions.isEmpty && retractedParts.isEmpty }
  }

  /// Nil when the blob is absent or not a plist. A plist with neither key decodes to an
  /// empty history rather than nil, so "unreadable" and "nothing happened" stay distinct.
  public static func decode(_ data: Data?) -> History? {
    guard let data, !data.isEmpty,
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let root = plist as? [String: Any]
    else { return nil }

    var revisions: [Int: [Revision]] = [:]
    if let edited = root["ec"] as? [String: Any] {
      for (key, value) in edited {
        guard let part = Int(key), let entries = value as? [[String: Any]] else { continue }
        revisions[part] = entries.compactMap { entry -> Revision? in
          guard let archive = entry["t"] as? Data,
            let body = try? AttributedBodyDecoder.decode(archive)
          else { return nil }
          return Revision(date: date(entry["d"]), text: body.text)
        }
      }
    }
    let retracted = (root["rp"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    return History(revisions: revisions, retractedParts: retracted.sorted())
  }

  /// `d` is a real: seconds since the Apple epoch. A plist date is accepted too.
  private static func date(_ value: Any?) -> Date? {
    if let date = value as? Date { return date }
    guard let number = value as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: number.doubleValue + appleEpochOffset)
  }
}
