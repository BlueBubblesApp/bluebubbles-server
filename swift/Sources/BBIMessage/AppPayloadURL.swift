//  AppPayloadURL
//  The handful of shapes an iMessage app's payload URL actually takes.
//
//  `MSMessage.URL` is whatever the extension decided, and this server does not get to pick.
//  But surveying every app balloon on a real Mac, only five shapes turn up:
//
//      data:,<base64 JSON>                  Polls
//      data:?<query string>                 Game Pigeon (its query is scrambled; see the codec)
//      data:<media type>;base64,<bytes>     Apple Pay
//      https://…                            Photos, YouTube, OpenTable, Game Center
//      ?<query string>                      Find My
//
//  Two of those are worth building for a caller — the base64-JSON one and the query one —
//  because they need encoding a client would otherwise have to get right itself. The rest
//  are URLs a caller already has in hand and can pass through untouched.

import Foundation

public enum AppPayloadURL {

  /// `data:,<base64 of the JSON>`, which is what Polls uses.
  public static func encodeJSON(_ json: Data) -> String {
    "data:," + json.base64EncodedString()
  }

  /// `data:?a=1&b=2`, the shape Game Pigeon's outer URL uses.
  public static func encodeFields(_ fields: [(name: String, value: String)]) -> String {
    "data:?" + fields.map { "\(escape($0.name))=\(escape($0.value))" }.joined(separator: "&")
  }

  /// The JSON bytes behind a `data:,…` URL, if that is what this is.
  ///
  /// Percent-decoded first and padded after: a real payload may be escaped in transit, and
  /// base64 in a URL is routinely written without its `=` padding.
  public static func decodeJSON(_ url: String) -> Data? {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
      !url[url.startIndex..<comma].contains(";")
    else { return nil }
    var body = String(url[url.index(after: comma)...])
    if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }
    body = body.removingPercentEncoding ?? body
    let padding = (4 - body.count % 4) % 4
    guard let data = Data(base64Encoded: body + String(repeating: "=", count: padding))
    else { return nil }
    // Only claim it when it really is JSON — plenty of `data:` bodies are not.
    guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    else { return nil }
    return data
  }

  /// The fields of a `data:?…` or bare `?…` payload, in order.
  public static func decodeFields(_ url: String) -> [(name: String, value: String)]? {
    let query: Substring
    if url.hasPrefix("data:?") {
      query = url.dropFirst("data:?".count)
    } else if url.hasPrefix("?") {
      query = url.dropFirst()
    } else {
      return nil
    }
    guard !query.isEmpty else { return nil }
    return parseQuery(String(query))
  }

  /// Percent-decoding pairs, keeping order and keeping empty values — an empty value is a
  /// real one in more than one of these formats.
  public static func parseQuery(_ query: String) -> [(name: String, value: String)] {
    query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
      let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      return (
        name: unescape(String(halves.first ?? "")),
        value: halves.count > 1 ? unescape(String(halves[1])) : ""
      )
    }
  }

  /// `+` is a space in a query string, and a stray `%` that is not an escape has to survive
  /// rather than blanking the field — Game Pigeon's `replay` is full of them.
  public static func unescape(_ text: String) -> String {
    let plussed = text.replacingOccurrences(of: "+", with: " ")
    return plussed.removingPercentEncoding ?? plussed
  }

  public static func escape(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }
}
