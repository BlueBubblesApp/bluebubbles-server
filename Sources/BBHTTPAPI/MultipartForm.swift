//  MultipartForm
//  A `multipart/form-data` reader, for attachment upload.
//
//  Written against the body bytes rather than a streaming parser because the HTTP layer
//  already caps and buffers the body at `maximumBodySize`; there is no larger body to
//  stream. Attachments above that cap go through the chunked upload route instead.
//
//  Operates on BYTES throughout. A multipart body carries arbitrary binary (a JPEG, a
//  video) and decoding it as a String to find the boundaries corrupts the payload while
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

    // The delimiter is CRLF + "--" + boundary, and the FIRST one has no leading CRLF.
    //
    // That difference used to be smoothed over by prefixing the whole body with CRLF, which
    // copied the entire upload to prepend two bytes: measured at a 50MB body growing the
    // process by 150MB, three times over, and this is the path an attachment upload takes on
    // a Mac that may have 4GB. The first delimiter is special-cased instead.
    let delimiter = Data("\r\n--\(boundary)".utf8)
    let openingDelimiter = Data("--\(boundary)".utf8)
    let closing = Data("--".utf8)
    let crlf = Data("\r\n".utf8)

    var parts: [Part] = []
    var boundaryRange: Range<Data.Index>? =
      body.starts(with: openingDelimiter)
      ? body.startIndex..<(body.startIndex + openingDelimiter.count)
      : body.range(of: delimiter, in: body.startIndex..<body.endIndex)

    while let range = boundaryRange {
      var cursor = range.upperBound

      // After the boundary comes either "--" (the final one) or CRLF.
      if body.endIndex - cursor >= 2 {
        let next = body[cursor..<(cursor + 2)]
        if next == closing { break }
        if next == crlf { cursor += 2 }
      }

      guard let nextRange = body.range(of: delimiter, in: cursor..<body.endIndex) else { break }

      // A SLICE, not a copy. `Data.SubSequence` is `Data`, so the parts share the body's
      // storage rather than each duplicating their own bytes -- which for an attachment
      // upload is nearly the whole body, twice.
      let section = body[cursor..<nextRange.lowerBound]
      if let part = try Self.parsePart(section) { parts.append(part) }
      boundaryRange = nextRange
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
    // Sliced, not copied: see `parse`. The headers are small enough that their copy does not
    // matter, but the body is the upload.
    let body = section[split.upperBound...]

    guard let headerText = String(data: headerBytes, encoding: .utf8) else {
      throw MultipartError.malformed("a part had non-UTF-8 headers")
    }

    var name: String?
    var filename: String?
    var contentType: String?

    for line in headerText.components(separatedBy: "\r\n") {
      let lower = line.lowercased()
      if lower.hasPrefix("content-disposition:") {
        let parameters = Self.dispositionParameters(in: line)
        // Empty reads as absent: a browser sends `filename=""` for a file input left empty,
        // and that part is not a file.
        name = parameters["name"].flatMap { $0.isEmpty ? nil : $0 }
        filename = parameters["filename"].flatMap { $0.isEmpty ? nil : $0 }
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

  /// The parameters of a `Content-Disposition` header line, keyed by lowercased name.
  ///
  /// Parsed as parameters, not searched for as text. A search for `name="` also matches
  /// inside `filename="`, so a part whose filename came first (`form-data;
  /// filename="photo.jpg"; name="attachment"`, which RFC 7578 permits) was read as a field
  /// called `photo.jpg`. Splitting on `;` outside quotes and comparing whole names cannot
  /// confuse the two.
  ///
  /// A value is a token or a quoted string. Inside quotes, `\"` is an escaped quote and any
  /// other backslash is kept as written: a Windows client sends a path's backslashes raw, and
  /// unescaping them would mangle the name. The first occurrence of a name wins.
  static func dispositionParameters(in line: String) -> [String: String] {
    guard let colon = line.firstIndex(of: ":") else { return [:] }

    let header = line[line.index(after: colon)...]
    var segments: [Substring] = []
    var segmentStart = header.startIndex
    var quoted = false
    var previous: Character?
    for index in header.indices {
      let character = header[index]
      if character == "\"", !(quoted && previous == "\\") {
        quoted.toggle()
      } else if character == ";", !quoted {
        segments.append(header[segmentStart..<index])
        segmentStart = header.index(after: index)
      }
      previous = character
    }
    segments.append(header[segmentStart...])

    var parameters: [String: String] = [:]
    // The first segment is the disposition type (`form-data`), not a parameter.
    for segment in segments.dropFirst() {
      guard let equals = segment.firstIndex(of: "=") else { continue }
      let key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      let raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, parameters[key] == nil else { continue }
      parameters[key] = unquoted(raw)
    }
    return parameters
  }

  /// A parameter value with its quotes and escaped quotes removed; a token unchanged.
  private static func unquoted(_ raw: String) -> String {
    guard raw.first == "\"" else { return raw }
    var out = ""
    var characters = raw.dropFirst()
    while let character = characters.popFirst() {
      if character == "\\", characters.first == "\"" {
        out.append(characters.removeFirst())
      } else if character == "\"" {
        break
      } else {
        out.append(character)
      }
    }
    return out
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
