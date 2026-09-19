//  Redaction
//  What an address looks like once it is allowed into a log line.
//
//  The log is the one artefact a person pastes into a public issue, so a phone number or
//  an email in it is a leak the moment the report is filed. Fully hiding them makes the log
//  useless for the question it is usually answering ("did the message to THAT chat go
//  out?"), so each is trimmed to what a reader can match against Messages.app and no more:
//  the country code and the last four digits of a phone number, the first two letters and
//  the domain of an email.
//
//  A chat GUID carries an address in its third field (`iMessage;-;+12025550143`), so it
//  gets the same treatment on that field alone; a group GUID (`iMessage;+;chat123`) names
//  a room, not a person, and passes through. A message GUID, an attachment GUID, a room
//  name, a transaction id and an event name are opaque and never need this.
//
//  These are the ONLY forms an address may take in log metadata. `LogRedactionPolicyTests`
//  scans the source for a metadata key that names an address and fails the build when its
//  value is not wrapped here. See `.claude/docs/architecture.md` § Diagnostics.

import Foundation

public enum Redaction {

  /// The ellipsis every redacted form carries, so a reader can tell "redacted" from "short".
  static let mask = "…"

  /// `+12025550143` → `+1…0143`; `someone@example.com` → `so…@example.com`.
  ///
  /// Anything too short to leave a useful remainder (fewer than six characters) becomes
  /// the bare mask: keeping four of five digits would not be redaction.
  public static func address(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let at = trimmed.lastIndex(of: "@"), at != trimmed.startIndex {
      let local = trimmed[..<at]
      let domain = trimmed[at...]
      return String(local.prefix(2)) + mask + domain
    }
    guard trimmed.count >= 6 else { return mask }

    var prefix = ""
    var digits = Substring(trimmed)
    if digits.first == "+" {
      prefix = "+"
      digits = digits.dropFirst()
      // The country code: one digit, which is what "+1" and "+4…" both leave readable
      // without narrowing a number to its region.
      if let first = digits.first, first.isNumber {
        prefix.append(first)
      }
    }
    return prefix + mask + trimmed.suffix(4)
  }

  /// A chat GUID with its address field redacted; a group GUID or an unparseable string
  /// comes back unchanged.
  public static func chatGUID(_ raw: String) -> String {
    guard let parsed = ChatGUID(raw), !parsed.isGroup else { return raw }
    return "\(parsed.servicePrefix);\(parsed.separator.rawValue);\(address(parsed.address))"
  }

  /// A URL reduced to what identifies it, with everything that can carry a credential gone.
  ///
  /// Clients routinely register webhook URLs with the server password in the query string,
  /// so logging the raw URL writes that secret to disk on every dispatch.
  ///
  /// **The path is a credential too, and this used to keep it.** The old rule blanked three
  /// named query values and kept the host and path, on the grounds that those identify the
  /// endpoint. That is true of a URL somebody designed; it is false of the two webhook
  /// providers this server is most often pointed at. A Discord webhook is
  /// `https://discord.com/api/webhooks/<id>/<token>`, and Slack's is the same shape: the
  /// secret IS a path component, and neither carries a query string at all, so the old
  /// implementation returned them completely unredacted. It also passed `user:password@`
  /// userinfo straight through, and matched query names by exact spelling, so `access_token`,
  /// `api_key`, `auth` and `secret` were all kept.
  ///
  /// That mattered because this is not confined to debug logging. `WebhookSink` logs the URL
  /// at WARNING after ten consecutive failures, and puts it in the alert body and the
  /// diagnostic context, which `Diagnostics.redactedReport()` prints into the bundle people
  /// paste into chat and issue trackers. So a webhook that went stale published its own live
  /// token to whoever was helping debug it.
  ///
  /// The rule now is: scheme, host, and the FIRST path component. That still answers "which
  /// endpoint is this" — `https://discord.com/api/…` is unmistakable — without betting that
  /// no provider puts a secret in a path.
  /// Redacts every URL found INSIDE a larger string.
  ///
  /// `url(_:)` takes a URL and nothing else, which is right where a URL is what you have.
  /// This is for the case where one is embedded in prose written by somebody else: a
  /// `URLError`'s description carries `NSErrorFailingURLKey=https://…` with the whole query
  /// string in it, and that description is stored on an alert and printed verbatim into the
  /// diagnostic bundle people paste into chat and issue trackers. Clients routinely put the
  /// server password in a webhook's query string, so that is a credential published by
  /// somebody trying to report a bug.
  public static func urls(in text: String) -> String {
    guard text.contains("://") else { return text }
    // A URL runs to the first whitespace or one of the few characters that reliably end one
    // in prose. Deliberately greedy about what it treats as part of the URL: over-redacting
    // a trailing bracket costs nothing, and stopping early would leave the query string.
    let pattern = /[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s"'<>]+/
    var result = ""
    var index = text.startIndex
    for match in text.matches(of: pattern) {
      result += text[index..<match.range.lowerBound]
      result += url(String(text[match.range]))
      index = match.range.upperBound
    }
    result += text[index...]
    return result
  }

  /// Query-name fragments that mean the value is a credential. Matched as SUBSTRINGS, so
  /// `access_token`, `apiKey`, `X-Auth` and `signature` are all caught by one entry each.
  /// A false positive costs a blanked value in a log; a false negative publishes a secret.
  private static let credentialNameFragments = [
    "password", "passwd", "secret", "token", "key", "auth", "sig", "credential", "session",
    "guid",
  ]

  public static func url(_ raw: String) -> String {
    // A scheme AND a host, or this is not a URL and rewriting it would only mangle it.
    // `URLComponents` happily parses "not a url" as a relative path and then re-serialises
    // it percent-encoded, which is a worse log line than the one we were given.
    guard var components = URLComponents(string: raw),
      components.scheme != nil, components.host != nil
    else { return raw }

    // Userinfo is a credential by construction and identifies nothing.
    components.user = nil
    components.password = nil

    if let items = components.queryItems {
      components.queryItems = items.map { item in
        let name = item.name.lowercased()
        return credentialNameFragments.contains(where: name.contains)
          ? URLQueryItem(name: item.name, value: "***")
          : item
      }
    }

    // The first path component is kept and the rest replaced. `/api/webhooks/<id>/<token>`
    // becomes `/api/...`, which still says which endpoint this is.
    //
    // ASCII in the placeholder on purpose: `percentEncodedPath` traps on a character it
    // would have to encode, so an ellipsis here is a crash in the logging path.
    let segments = components.percentEncodedPath.split(
      separator: "/", omittingEmptySubsequences: true)
    if segments.count > 1 {
      components.percentEncodedPath = "/" + segments[0] + "/..."
    }

    // A fragment is never needed to identify an endpoint and can carry anything.
    if components.fragment != nil { components.percentEncodedFragment = "..." }

    return components.string ?? raw
  }
}
