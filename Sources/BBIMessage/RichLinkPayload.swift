//  RichLinkPayload
//  The preview Messages stores for a bare URL: title, summary, site, and the link itself.
//
//  A rich link (`balloon_bundle_id` of `com.apple.messages.URLBalloonProvider`) carries an
//  `NSKeyedArchiver` graph of Messages' own `RichLink` wrapping an `LPLinkMetadata`.
//  `RichLink` exists only inside Messages.app, so a secure unarchive refuses the graph, and
//  the tolerant unarchive `AppMessagePayload` uses stands a placeholder in for the class,
//  which decodes nothing: the fields are inside the object the placeholder discards.
//
//  So this reads the archive as a property list and walks `$objects` by hand, resolving
//  UIDs, exactly as the BlueBubbles client does (`payload_data.dart`, `extractUIDs`): find
//  the object with a `URL` or a `title`, and read its fields. The key spellings are
//  `LPLinkMetadata`'s own and the client reads the same ones, so an export and the app
//  describe one link with the same words.

import Foundation

public enum RichLinkPayload {

  public struct Link: Equatable, Sendable {
    public let url: String?
    public let originalURL: String?
    public let title: String?
    public let summary: String?
    public let siteName: String?

    public init(
      url: String? = nil, originalURL: String? = nil, title: String? = nil,
      summary: String? = nil, siteName: String? = nil
    ) {
      self.url = url
      self.originalURL = originalURL
      self.title = title
      self.summary = summary
      self.siteName = siteName
    }

    var isEmpty: Bool {
      url == nil && originalURL == nil && title == nil && summary == nil && siteName == nil
    }
  }

  /// The preview, or nil when the blob is absent, not a keyed archive, or holds no link.
  public static func decode(_ data: Data?) -> Link? {
    guard let data, !data.isEmpty,
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let archive = plist as? [String: Any],
      let objects = archive["$objects"] as? [Any],
      let top = archive["$top"] as? [String: Any],
      let rootUID = uid(top["root"])
    else { return nil }
    var visited = Set<Int>()
    let root = resolve(objects, index: rootUID, visited: &visited, depth: 0)
    guard let metadata = findMetadata(in: root, depth: 0) else { return nil }
    let link = Link(
      url: string(metadata["URL"]), originalURL: string(metadata["originalURL"]),
      title: metadata["title"] as? String, summary: metadata["summary"] as? String,
      siteName: metadata["siteName"] as? String)
    return link.isEmpty ? nil : link
  }

  /// Objects nested more deeply than this are not worth following: a link's metadata sits
  /// one or two levels below the root.
  private static let maximumDepth = 8

  /// The dictionary that carries the link: the first one, walking down, with a `URL` or a
  /// `title` key.
  private static func findMetadata(in object: Any, depth: Int) -> [String: Any]? {
    guard depth < maximumDepth else { return nil }
    if let dictionary = object as? [String: Any] {
      if dictionary["URL"] != nil || dictionary["title"] != nil { return dictionary }
      for value in dictionary.values {
        if let found = findMetadata(in: value, depth: depth + 1) { return found }
      }
    }
    if let array = object as? [Any] {
      for value in array {
        if let found = findMetadata(in: value, depth: depth + 1) { return found }
      }
    }
    return nil
  }

  /// A URL object resolves to `{ "NS.relative": "https://…" }`; a string is itself.
  private static func string(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let dictionary = value as? [String: Any] {
      if let relative = dictionary["NS.relative"] as? String { return relative }
      if let string = dictionary["NS.string"] as? String { return string }
    }
    return nil
  }

  /// Replaces every UID in the object at `index` with the object it points at, turning the
  /// archive's `NS.keys`/`NS.objects` pairs back into dictionaries on the way.
  private static func resolve(
    _ objects: [Any], index: Int, visited: inout Set<Int>, depth: Int
  ) -> Any {
    guard index >= 0, index < objects.count, depth < maximumDepth, !visited.contains(index)
    else { return NSNull() }
    visited.insert(index)
    defer { visited.remove(index) }
    return resolve(objects, value: objects[index], visited: &visited, depth: depth)
  }

  private static func resolve(
    _ objects: [Any], value: Any, visited: inout Set<Int>, depth: Int
  ) -> Any {
    if let uid = uid(value) {
      return resolve(objects, index: uid, visited: &visited, depth: depth + 1)
    }
    if let array = value as? [Any] {
      return array.map { resolve(objects, value: $0, visited: &visited, depth: depth + 1) }
    }
    guard let dictionary = value as? [String: Any] else { return value }
    var resolved: [String: Any] = [:]
    if let keys = dictionary["NS.keys"] as? [Any], let values = dictionary["NS.objects"] as? [Any],
      keys.count == values.count
    {
      for (key, object) in zip(keys, values) {
        let name = resolve(objects, value: key, visited: &visited, depth: depth + 1)
        guard let name = name as? String else { continue }
        resolved[name] = resolve(objects, value: object, visited: &visited, depth: depth + 1)
      }
    }
    for (key, object) in dictionary where key != "NS.keys" && key != "NS.objects" {
      // `$class` is a UID to the class description, which says nothing about the link.
      if key == "$class" { continue }
      resolved[key] = resolve(objects, value: object, visited: &visited, depth: depth + 1)
    }
    return resolved
  }

  /// The integer inside a keyed-archiver UID, read by re-encoding the one object: the type
  /// has no public accessor. The same trick `PropertyListWire.uidValue` documents.
  private static func uid(_ value: Any?) -> Int? {
    guard let value, !(value is String), !(value is NSNumber), !(value is [Any]),
      !(value is [String: Any]), !(value is Data), !(value is Date)
    else { return nil }
    guard
      let encoded = try? PropertyListSerialization.data(
        fromPropertyList: value, format: .binary, options: 0),
      encoded.count > 9
    else { return nil }
    let marker = encoded[8]
    guard marker & 0xF0 == 0x80 else { return nil }
    let width = Int(marker & 0x0F) + 1
    guard encoded.count >= 9 + width else { return nil }
    return encoded[9..<(9 + width)].reduce(0) { $0 << 8 | Int($1) }
  }
}
