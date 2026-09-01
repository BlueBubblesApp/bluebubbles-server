//  AppcastParser
//  Reads an appcast feed.
//
//  Used by `GET /api/v1/server/update/check`, which reads the same feed Sparkle does. Sharing
//  the feed rather than querying the GitHub releases API separately is what keeps the two from
//  disagreeing — the current server polls GitHub while its updater reads something else, so
//  the API can report an update the updater will not install.

import BBCore
import Foundation

public enum AppcastParser {

  public enum ParseError: BBError, Equatable, LocalizedError {
    case malformedXML(String)

    public var errorDescription: String? {
      switch self {
      case .malformedXML(let reason): "The appcast could not be read: \(reason)"
      }
    }
  }

  public static func parse(_ data: Data) throws -> Appcast {
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = false

    guard parser.parse() else {
      throw ParseError.malformedXML(
        parser.parserError.map { String(describing: $0) } ?? "unknown"
      )
    }
    return delegate.appcast
  }

  /// Accumulates elements as they stream past.
  ///
  /// `XMLParser` is a streaming parser and hands text through in ARBITRARY chunks — a long
  /// release-note body arrives in several `foundCharacters` calls. Appending rather than
  /// assigning is what keeps a description from being truncated to its last fragment, which
  /// is the classic bug with this API and looks like a data problem rather than a parsing
  /// one.
  private final class Delegate: NSObject, XMLParserDelegate {

    var appcast = Appcast(items: [])
    private var text = ""
    private var item: AppcastItem?
    private var insideItem = false
    private var insideChannel = false

    func parser(
      _ parser: XMLParser,
      didStartElement element: String,
      namespaceURI: String?,
      qualifiedName: String?,
      attributes: [String: String]
    ) {
      text = ""
      switch element {
      case "channel":
        insideChannel = true
      case "item":
        insideItem = true
        item = AppcastItem(
          shortVersion: "", version: "",
          downloadURL: "", lengthInBytes: 0, edSignature: ""
        )
      case "enclosure":
        item?.downloadURL = attributes["url"] ?? ""
        item?.lengthInBytes = attributes["length"].flatMap(Int.init) ?? 0
        // Both spellings: `sparkle:edSignature` when namespaces are not processed,
        // and the bare form if a generator emitted it without the prefix.
        item?.edSignature =
          attributes["sparkle:edSignature"]
          ?? attributes["edSignature"] ?? ""
      default:
        break
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      text += string
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
      text += String(data: cdataBlock, encoding: .utf8) ?? ""
    }

    func parser(
      _ parser: XMLParser,
      didEndElement element: String,
      namespaceURI: String?,
      qualifiedName: String?
    ) {
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

      if insideItem {
        switch element {
        case "title": item?.title = value
        case "sparkle:version": item?.version = value
        case "sparkle:shortVersionString": item?.shortVersion = value
        case "sparkle:minimumSystemVersion": item?.minimumSystemVersion = value
        case "description": item?.releaseNotesHTML = value.isEmpty ? nil : value
        case "pubDate":
          if let date = Appcast.rfc822.date(from: value) { item?.publishedAt = date }
        case "item":
          // Kept only if it names a version and something to download. A partial
          // entry offered as an update is worse than one silently skipped: Sparkle
          // would show it and then fail at install.
          if var finished = item, !finished.version.isEmpty, !finished.downloadURL.isEmpty {
            if finished.shortVersion.isEmpty { finished.shortVersion = finished.version }
            appcast.items.append(finished)
          }
          item = nil
          insideItem = false
        default:
          break
        }
      } else if insideChannel {
        switch element {
        case "title": appcast.title = value
        case "link": appcast.link = value.isEmpty ? nil : value
        case "description": appcast.description = value.isEmpty ? nil : value
        case "channel": insideChannel = false
        default: break
        }
      }
      text = ""
    }
  }
}

extension AppcastParser.ParseError {
  public var code: String {
    switch self {
    case .malformedXML: "appcast.malformed_x_m_l"
    }
  }

  public var domain: String { "Updates" }

  public var title: String { "The update feed could not be read" }

  public var body: String { errorDescription ?? "This failed and reported no reason." }
}
