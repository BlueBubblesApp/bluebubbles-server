//  MultipartForm
//  A `multipart/form-data` reader, for attachment upload.
//
//  Written against the body bytes rather than a streaming parser because the HTTP layer
//  already caps and buffers the body at `maximumBodySize` — there is no larger body to
//  stream. Attachments above that cap go through the chunked upload route instead.
//
//  Operates on BYTES throughout. A multipart body carries arbitrary binary — a JPEG, a
//  video — and decoding it as a String to find the boundaries corrupts the payload while
//  appearing to work, since the headers around it are ASCII and look fine.

import BBCore
import Foundation

public struct MultipartForm: Sendable {

  public struct Part: Sendable {
    /// The form field name.
    public let name: String
    /// Present only for a file part.
    public let filename: String?
    public let contentType: String?
    public let data: Data

    /// The part's bytes as text, for an ordinary form field.
    public var text: String? { String(data: data, encoding: .utf8) }
  }

  public let parts: [Part]

  public subscript(name: String) -> Part? {
    parts.first { $0.name == name }
  }

  public enum MultipartError: BBError, Equatable {
    case notMultipart
    case missingBoundary
    case malformed(String)
  }

  /// Parses a body against the boundary from its Content-Type header.
  public static func parse(body: Data, contentType: String) throws -> MultipartForm {
    guard contentType.lowercased().contains("multipart/form-data") else {
      throw MultipartError.notMultipart
    }
    guard let boundary = Self.boundary(in: contentType) else {
      throw MultipartError.missingBoundary
    }

    // The delimiter is CRLF + "--" + boundary. The first one has no leading CRLF, which
    // is why the body is prefixed here rather than special-cased below.
    let delimiter = Data("\r\n--\(boundary)".utf8)
    let prefixed = Data("\r\n".utf8) + body

    var parts: [Part] = []
    var searchStart = prefixed.startIndex

    while let range = prefixed.range(of: delimiter, in: searchStart..<prefixed.endIndex) {
      var cursor = range.upperBound

      // After the boundary comes either "--" (the final one) or CRLF.
      if prefixed.count >= cursor + 2 {
        let next = prefixed[cursor..<(cursor + 2)]
        if next == Data("--".utf8) { break }
        if next == Data("\r\n".utf8) { cursor += 2 }
      }

      guard
        let nextRange = prefixed.range(
          of: delimiter, in: cursor..<prefixed.endIndex
        )
      else { break }

      let section = prefixed[cursor..<nextRange.lowerBound]
      if let part = try Self.parsePart(Data(section)) { parts.append(part) }
      searchStart = nextRange.lowerBound
    }

    return MultipartForm(parts: parts)
  }

  /// Reads the `boundary` parameter, quoted or bare.
  static func boundary(in contentType: String) -> String? {
    for component in contentType.split(separator: ";") {
      let trimmed = component.trimmingCharacters(in: .whitespaces)
      guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
      var value = String(trimmed.dropFirst("boundary=".count))
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      return value.isEmpty ? nil : value
    }
    return nil
  }

  private static func parsePart(_ section: Data) throws -> Part? {
    // Headers and body are separated by a blank line.
    let separator = Data("\r\n\r\n".utf8)
    guard let split = section.range(of: separator) else {
      throw MultipartError.malformed("a part had no header separator")
    }
    let headerBytes = section[section.startIndex..<split.lowerBound]
    let body = Data(section[split.upperBound...])

    guard let headerText = String(data: Data(headerBytes), encoding: .utf8) else {
      throw MultipartError.malformed("a part had non-UTF-8 headers")
    }

    var name: String?
    var filename: String?
    var contentType: String?

    for line in headerText.components(separatedBy: "\r\n") {
      let lower = line.lowercased()
      if lower.hasPrefix("content-disposition:") {
        name = Self.parameter("name", in: line)
        filename = Self.parameter("filename", in: line)
      } else if lower.hasPrefix("content-type:") {
        contentType =
          line
          .dropFirst("content-type:".count)
          .trimmingCharacters(in: .whitespaces)
      }
    }

    // A part with no name is not addressable, so there is nothing a caller could do
    // with it. Skipped rather than raised: some clients emit a stray epilogue part.
    guard let name else { return nil }
    return Part(name: name, filename: filename, contentType: contentType, data: body)
  }

  /// Reads `name="value"` out of a header line.
  static func parameter(_ key: String, in line: String) -> String? {
    guard let range = line.range(of: "\(key)=\"") else { return nil }
    let rest = line[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let value = String(rest[rest.startIndex..<end])
    return value.isEmpty ? nil : value
  }
}

extension MultipartForm.MultipartError {
  public var code: String {
    switch self {
    case .notMultipart: "multipart.not_multipart"
    case .missingBoundary: "multipart.missing_boundary"
    case .malformed: "multipart.malformed"
    }
  }

  public var domain: String { "HTTP" }

  public var title: String { "An upload could not be read" }

  public var body: String {
    switch self {
    case .notMultipart: "The request was not a multipart form."
    case .missingBoundary: "The multipart form declared no boundary."
    case .malformed(let detail): detail
    }
  }
}
