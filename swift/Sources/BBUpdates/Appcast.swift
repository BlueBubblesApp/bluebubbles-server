//  Appcast
//  The Sparkle appcast: the feed shipped installs read to discover updates.
//
//  Both directions live here, and deliberately so. The release pipeline WRITES an appcast and
//  `GET /api/v1/server/update/check` READS one; two implementations of the same XML would
//  drift, and the failure mode of that drift is silent — a feed the pipeline considers valid
//  and shipped clients ignore, which nobody notices until users stop receiving updates.
//
//  Replaces the current server's hand-rolled 12-hour GitHub-releases poll, whose "install"
//  action merely opens the release page in a browser. See `CONTRIBUTING.md`.

import BBCore
import Foundation

/// One release in the feed.
public struct AppcastItem: Sendable, Equatable {
  /// The marketing version — `CFBundleShortVersionString`, e.g. `1.2.3`.
  public var shortVersion: String
  /// The build number Sparkle actually compares — `CFBundleVersion`. Monotonic.
  public var version: String
  public var title: String
  public var publishedAt: Date
  public var releaseNotesHTML: String?
  public var downloadURL: String
  public var lengthInBytes: Int
  /// Base64 Ed25519 signature over the download's bytes.
  ///
  /// Sparkle refuses an update whose signature does not verify against the public key
  /// baked into the installed app, which is the whole security model: the download is
  /// served over HTTPS from GitHub, but the signature is what proves *we* built it.
  public var edSignature: String
  /// Minimum macOS. Sparkle hides the update from anything older rather than offering an
  /// install that would fail.
  public var minimumSystemVersion: String

  public init(
    shortVersion: String,
    version: String,
    title: String? = nil,
    publishedAt: Date = Date(),
    releaseNotesHTML: String? = nil,
    downloadURL: String,
    lengthInBytes: Int,
    edSignature: String,
    minimumSystemVersion: String = "14.0"
  ) {
    self.shortVersion = shortVersion
    self.version = version
    self.title = title ?? shortVersion
    self.publishedAt = publishedAt
    self.releaseNotesHTML = releaseNotesHTML
    self.downloadURL = downloadURL
    self.lengthInBytes = lengthInBytes
    self.edSignature = edSignature
    self.minimumSystemVersion = minimumSystemVersion
  }
}

public struct Appcast: Sendable, Equatable {
  public var title: String
  public var link: String?
  public var description: String?
  /// Newest first. `newestItem` relies on this ordering being enforced, not assumed.
  public var items: [AppcastItem]

  public init(
    title: String = "BlueBubbles Server",
    link: String? = nil,
    description: String? = nil,
    items: [AppcastItem] = []
  ) {
    self.title = title
    self.link = link
    self.description = description
    self.items = items
  }

  /// The highest version in the feed.
  ///
  /// Compared by `version` (the build number) rather than by position: an appcast that
  /// accumulated items out of order would otherwise offer an older build as the update,
  /// and Sparkle would then refuse to install it, leaving users stuck with no explanation.
  public var newestItem: AppcastItem? {
    items.max { SemanticVersion($0.version) < SemanticVersion($1.version) }
  }
}

// MARK: - Writing

extension Appcast {

  /// Renders the feed.
  ///
  /// Hand-written rather than built through a serializer because the namespace prefix
  /// matters: Sparkle looks for `sparkle:` bound to `http://www.andymatuschak.org/xml-namespaces/sparkle`
  /// exactly, and a generator that picked its own prefix would produce a feed that parses
  /// as XML and means nothing to Sparkle.
  public func xmlString(generatedAt: Date = Date()) -> String {
    var lines: [String] = [
      #"<?xml version="1.0" encoding="utf-8"?>"#,
      #"<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">"#,
      "    <channel>",
      "        <title>\(Self.escape(title))</title>",
    ]
    if let link { lines.append("        <link>\(Self.escape(link))</link>") }
    if let description {
      lines.append("        <description>\(Self.escape(description))</description>")
    }

    // Newest first, so a client reading the feed top-down sees the current release
    // first even if it does not sort.
    let ordered = items.sorted { SemanticVersion($0.version) > SemanticVersion($1.version) }
    for item in ordered {
      lines.append("        <item>")
      lines.append("            <title>\(Self.escape(item.title))</title>")
      lines.append("            <pubDate>\(Self.rfc822.string(from: item.publishedAt))</pubDate>")
      lines.append("            <sparkle:version>\(Self.escape(item.version))</sparkle:version>")
      lines.append(
        "            <sparkle:shortVersionString>\(Self.escape(item.shortVersion))"
          + "</sparkle:shortVersionString>"
      )
      lines.append(
        "            <sparkle:minimumSystemVersion>\(Self.escape(item.minimumSystemVersion))"
          + "</sparkle:minimumSystemVersion>"
      )
      if let notes = item.releaseNotesHTML, !notes.isEmpty {
        // CDATA, not escaped: release notes are HTML and Sparkle renders them. The
        // guard below is what keeps a note containing `]]>` from ending the section
        // early and producing invalid XML.
        lines.append(
          "            <description><![CDATA[\(Self.sanitizeCDATA(notes))]]></description>")
      }
      lines.append("            <enclosure")
      lines.append("                url=\"\(Self.escape(item.downloadURL))\"")
      lines.append("                length=\"\(item.lengthInBytes)\"")
      lines.append("                type=\"application/octet-stream\"")
      lines.append("                sparkle:edSignature=\"\(Self.escape(item.edSignature))\" />")
      lines.append("        </item>")
    }

    lines.append("    </channel>")
    lines.append("</rss>")
    return lines.joined(separator: "\n") + "\n"
  }

  /// RFC 822, which is what RSS requires.
  ///
  /// Locale and time zone are PINNED. Without them the format follows the build machine's
  /// settings, so a release cut on a machine set to French produces `mer.` for Wednesday
  /// and every RSS reader rejects the date.
  public static var rfc822: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter
  }

  public static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  /// Splits any `]]>` so it cannot terminate the CDATA section it sits inside.
  public static func sanitizeCDATA(_ value: String) -> String {
    value.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
  }
}
