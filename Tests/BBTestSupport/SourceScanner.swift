//  SourceScanner
//  The one walk over the tree that every source-scanning policy test reads.
//
//  A rule the compiler cannot check ships with a test that scans the source for it, and
//  there are dozens. Each used to hand-roll the same three steps (walk a directory, drop
//  the comments, report the offenders) and they had drifted on every one: which roots
//  were scanned, whether `.build` was excluded, whether a scan that found nothing failed,
//  and above all what a comment IS. Most treated a line as a comment when it STARTED with
//  `//`, so a trailing `// never X` counted as code and a `/* … */` block counted as code
//  throughout; a few did better. The same line was a finding in one policy and invisible to
//  the next.
//
//  So this file decides, once:
//
//  - **What a comment is** comes from a lexer, not a prefix test. `//` to the end of the
//    line and `/* … */` (which nests in Swift) are comments; the same characters inside a
//    string literal, raw or multi-line, are not. `SourceLine.code` is the line with its
//    comments removed and its strings intact, because several policies are ABOUT string
//    literals; `SourceLine.comment` is the comment text, for the policies about prose.
//  - **What is scanned** is every file under the named roots, skipping any hidden directory
//    beneath them (`.build`, `.git`, `.swiftpm`), any `node_modules` (someone else's code,
//    installed rather than committed), and `.claude/worktrees`, whose copies of the tree
//    would otherwise be scanned twice and report findings that are not in it.
//  - **A scan that finds too little throws.** Every call has a floor, at least one file,
//    because a policy test that reads an empty tree passes, and a moved directory is
//    exactly how a tree goes empty.
//  - **Each file is read once and lexed once per test process.** A policy that checks
//    several rules walks the same files once per rule, and dozens of policies share one
//    process; reading and lexing on every pass made the scans several times slower than
//    the prefix test they replaced. The tree does not change while the tests run, so a
//    file is cached by its path the first time a scan reaches it.

import BBCore
import Foundation

// MARK: - Files

/// A file found by a scan.
public struct SourceFile: Sendable {
  /// Relative to the repository root: `Sources/BBCore/Timeout.swift`. What a report prints,
  /// and what an exemption list names.
  public let path: String
  public let url: URL
  public let text: String
  /// Shared by every copy of this file, so a policy that asks again, or another policy
  /// handed the same cached file, does not lex it again.
  private let lexed = Locked<[SourceLine]?>(nil)

  public init(path: String, url: URL, text: String) {
    self.path = path
    self.url = url
    self.text = text
  }

  /// The file's lines, each split into code and comment. Lexed on first read.
  public var lines: [SourceLine] {
    if let lines = lexed.value { return lines }
    // Lexed outside the lock: two readers racing here both lex and store the same lines,
    // which costs one duplicate pass rather than holding a lock through the work.
    let lines = SwiftLexer.lines(of: text)
    lexed.withLock { $0 = lines }
    return lines
  }

  /// The lines that carry code, with their comments removed. Blank lines and lines that
  /// are only comment are left out.
  public var codeLines: [SourceLine] {
    lines.filter { !$0.code.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// The text with every comment removed and the line structure kept, for a policy that
  /// matches across lines.
  public var code: String { lines.map(\.code).joined(separator: "\n") }

  /// The file's name without its directory.
  public var name: String { url.lastPathComponent }
}

extension [SourceFile] {
  /// The files' text, end to end, for a wiring check that asks whether a type contains a
  /// line and does not care which of its files holds it.
  public var text: String { map(\.text).joined(separator: "\n") }

  /// The files' code with comments removed, end to end.
  public var code: String { map(\.code).joined(separator: "\n") }
}

/// One line of a file.
public struct SourceLine: Sendable, Equatable {
  /// One-based, as an editor counts.
  public let number: Int
  /// The line as written.
  public let text: String
  /// The line with comments removed. String literals are kept.
  public let code: String
  /// The text of any comment on the line, without its `//`, `/*` or `*/` markers.
  public let comment: String

  public init(number: Int, text: String, code: String, comment: String) {
    self.number = number
    self.text = text
    self.code = code
    self.comment = comment
  }

  /// Whether the line holds nothing but comment (and whitespace).
  public var isComment: Bool {
    code.trimmingCharacters(in: .whitespaces).isEmpty
      && !comment.trimmingCharacters(in: .whitespaces).isEmpty
  }
}

// MARK: - Scanning

public enum SourceScanner {

  /// Every file under `roots` with one of `extensions`.
  ///
  /// - Parameters:
  ///   - roots: Directories relative to the repository root (`"Sources"`, `"Helper"`). An
  ///     empty string is the root itself, which only makes sense with `recursive: false`.
  ///   - extensions: Lowercased, without the dot.
  ///   - recursive: False to read only the files directly inside each root, as a scan of the
  ///     top-level documents does.
  ///   - minimum: The fewest files this scan may find. Never less than one.
  /// - Throws: `SourceScanError.tooFewFiles` when the scan finds fewer than `minimum`, and
  ///   any error reading a file.
  public static func files(
    under roots: [String],
    extensions: Set<String> = ["swift"],
    recursive: Bool = true,
    minimum: Int = 1
  ) throws -> [SourceFile] {
    var found: [SourceFile] = []
    for root in roots {
      for url in try urls(under: root, recursive: recursive)
      where extensions.contains(url.pathExtension.lowercased()) {
        found.append(try load(url, path: relativePath(of: url)))
      }
    }
    guard found.count >= max(minimum, 1) else {
      throw SourceScanError.tooFewFiles(roots: roots, found: found.count, minimum: max(minimum, 1))
    }
    return found.sorted { $0.path < $1.path }
  }

  /// The Swift files under `roots`. The common case, spelled shortly.
  public static func swiftFiles(under roots: String..., minimum: Int = 1) throws -> [SourceFile] {
    try files(under: roots, minimum: minimum)
  }

  /// One file, named relative to the repository root, for a policy about a single file.
  ///
  /// - Throws: Any error reading it, so a moved file fails the policy rather than emptying it.
  public static func file(_ relative: String) throws -> SourceFile {
    try load(Repository.url(relative), path: relative)
  }

  /// A file and the extension files split out of it: `ServerComposition.swift` and every
  /// `ServerComposition+*.swift` in the same directory, for a policy about one type that
  /// spans several files. Splitting a type then changes no test, and a policy cannot pass by
  /// reading the half of the type that no longer holds the line it looks for.
  ///
  /// - Throws: Any error reading the primary file, so a moved file fails the policy rather
  ///   than emptying it.
  public static func family(_ relative: String) throws -> [SourceFile] {
    let primary = try file(relative)
    let directory = primary.url.deletingLastPathComponent()
    let stem = primary.url.deletingPathExtension().lastPathComponent
    let siblings = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(stem + "+") }
    .map { try load($0, path: relativePath(of: $0)) }
    return [primary] + siblings.sorted { $0.path < $1.path }
  }

  /// Every file a scan has read in this process, by path.
  private static let cache = Locked<[String: SourceFile]>([:])

  /// The file at `url`, read once per process.
  private static func load(_ url: URL, path: String) throws -> SourceFile {
    if let cached = cache.value[path] { return cached }
    let file = SourceFile(path: path, url: url, text: try String(contentsOf: url, encoding: .utf8))
    cache.withLock { $0[path] = file }
    return file
  }

  /// Every line of `files` that `matches` accepts, as a report-ready list.
  public static func offences(
    in files: [SourceFile],
    where matches: (SourceFile, SourceLine) -> Bool
  ) -> [Offence] {
    files.flatMap { file in
      file.lines.filter { matches(file, $0) }.map { Offence(file, $0) }
    }
  }

  private static func urls(under root: String, recursive: Bool) throws -> [URL] {
    let base = Repository.url(root).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw SourceScanError.missingRoot(root) }

    guard recursive else {
      return try FileManager.default.contentsOfDirectory(
        at: base, includingPropertiesForKeys: [.isRegularFileKey]
      ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    guard
      let walker = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
    else { throw SourceScanError.missingRoot(root) }

    var urls: [URL] = []
    for case let url as URL in walker {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values.isDirectory == true {
        if isSkipped(directory: url) { walker.skipDescendants() }
        continue
      }
      if values.isRegularFile == true { urls.append(url) }
    }
    return urls
  }

  /// A hidden directory beneath a root, a package manager's vendored tree, or an agent's
  /// worktree.
  private static func isSkipped(directory url: URL) -> Bool {
    let name = url.lastPathComponent
    if name.hasPrefix(".") || name == "node_modules" { return true }
    return name == "worktrees" && url.deletingLastPathComponent().lastPathComponent == ".claude"
  }

  private static func relativePath(of url: URL) -> String {
    let rootPath = Repository.root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else { return path }
    return String(path.dropFirst(rootPath.count).drop { $0 == "/" })
  }
}

public enum SourceScanError: Error, CustomStringConvertible {
  case missingRoot(String)
  case tooFewFiles(roots: [String], found: Int, minimum: Int)

  public var description: String {
    switch self {
    case .missingRoot(let root):
      "There is no directory at \(Repository.url(root).path), so this scan would read nothing."
    case .tooFewFiles(let roots, let found, let minimum):
      "Scanning \(roots.joined(separator: ", ")) found \(found) file(s), fewer than the "
        + "\(minimum) this policy expects, so it would pass having read almost nothing."
    }
  }
}

// MARK: - Reporting

/// A line a policy refused, printed as `path:line: text` so an editor can jump to it.
public struct Offence: Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let line: Int
  public let text: String

  public init(path: String, line: Int, text: String) {
    self.path = path
    self.line = line
    self.text = text
  }

  public init(_ file: SourceFile, _ line: SourceLine) {
    self.init(path: file.path, line: line.number, text: line.text)
  }

  public var description: String {
    "\(path):\(line): \(text.trimmingCharacters(in: .whitespaces))"
  }
}

extension Sequence where Element == Offence {
  /// One offence per line, ready to hand to `#expect` as its message.
  public var report: String { map(\.description).joined(separator: "\n") }
}

// MARK: - The lexer

/// Splits Swift source into code and comment, line by line.
///
/// Byte-wise, because every delimiter it cares about is ASCII, and because `Character`
/// would read `\r\n` as one grapheme and miscount the lines. Handles line and nested
/// block comments, plain, raw (`#"…"#`) and multi-line (`"""`) strings, escapes, and
/// interpolation, which can itself hold strings and comments. A regex literal is read as
/// code, which is wrong only for one containing `//` or a quote.
enum SwiftLexer {

  private enum Mode {
    case code
    case lineComment
    case blockComment(depth: Int)
    case string(hashes: Int, multiline: Bool)
  }

  private struct Frame {
    var mode: Mode
    /// For a code frame opened by an interpolation: the parentheses still open, so the
    /// `)` that closes the interpolation can be told from one inside it.
    var parentheses = 0
  }

  private static let newline = UInt8(ascii: "\n")
  private static let slash = UInt8(ascii: "/")
  private static let star = UInt8(ascii: "*")
  private static let quote = UInt8(ascii: "\"")
  private static let hash = UInt8(ascii: "#")
  private static let backslash = UInt8(ascii: "\\")
  private static let openParen = UInt8(ascii: "(")
  private static let closeParen = UInt8(ascii: ")")

  static func lines(of text: String) -> [SourceLine] {
    let bytes = Array(text.utf8)
    var lines: [SourceLine] = []
    var stack = [Frame(mode: .code)]
    var lineStart = 0
    var code: [UInt8] = []
    var comment: [UInt8] = []
    var index = 0

    func finishLine(at end: Int) {
      lines.append(
        SourceLine(
          number: lines.count + 1,
          text: String(decoding: bytes[lineStart..<end], as: UTF8.self),
          code: String(decoding: code, as: UTF8.self),
          comment: String(decoding: comment, as: UTF8.self)))
      code.removeAll(keepingCapacity: true)
      comment.removeAll(keepingCapacity: true)
      lineStart = end + 1
    }

    func at(_ offset: Int, is byte: UInt8) -> Bool {
      index + offset < bytes.count && bytes[index + offset] == byte
    }

    func hashes(from start: Int) -> Int {
      var count = 0
      while start + count < bytes.count, bytes[start + count] == hash { count += 1 }
      return count
    }

    while index < bytes.count {
      let byte = bytes[index]

      if byte == newline {
        switch stack[stack.count - 1].mode {
        case .lineComment: stack[stack.count - 1].mode = .code
        case .string(_, multiline: false):
          // An unterminated single-line string. Not valid Swift; recover rather than
          // reading the rest of the file as one string.
          stack = [Frame(mode: .code)]
        default: break
        }
        finishLine(at: index)
        index += 1
        continue
      }

      switch stack[stack.count - 1].mode {
      case .lineComment:
        comment.append(byte)
        index += 1

      case .blockComment(let depth):
        if byte == star, at(1, is: slash) {
          index += 2
          stack[stack.count - 1].mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
        } else if byte == slash, at(1, is: star) {
          index += 2
          stack[stack.count - 1].mode = .blockComment(depth: depth + 1)
        } else {
          comment.append(byte)
          index += 1
        }

      case .string(let hashCount, let multiline):
        if byte == backslash, hashes(from: index + 1) == hashCount {
          let after = index + 1 + hashCount
          if after < bytes.count, bytes[after] == openParen {
            // Interpolation: code until the matching `)`.
            code.append(contentsOf: bytes[index...after])
            index = after + 1
            stack.append(Frame(mode: .code, parentheses: 1))
          } else {
            // An escape. The escaped byte is taken whatever it is, so `\"` does not close.
            let end = min(after + 1, bytes.count)
            code.append(contentsOf: bytes[index..<end])
            index = end
          }
        } else if byte == quote, !multiline || (at(1, is: quote) && at(2, is: quote)),
          hashes(from: index + (multiline ? 3 : 1)) >= hashCount
        {
          let end = index + (multiline ? 3 : 1) + hashCount
          code.append(contentsOf: bytes[index..<end])
          index = end
          stack[stack.count - 1].mode = .code
        } else {
          code.append(byte)
          index += 1
        }

      case .code:
        if byte == slash, at(1, is: slash) {
          index += 2
          stack[stack.count - 1].mode = .lineComment
        } else if byte == slash, at(1, is: star) {
          index += 2
          stack[stack.count - 1].mode = .blockComment(depth: 1)
        } else if byte == hash || byte == quote {
          let hashCount = hashes(from: index)
          let quoteAt = index + hashCount
          guard quoteAt < bytes.count, bytes[quoteAt] == quote else {
            // A `#` that opens no string: `#if`, `#available`, `#filePath`.
            code.append(contentsOf: bytes[index..<quoteAt])
            index = quoteAt
            continue
          }
          let multiline =
            quoteAt + 2 < bytes.count && bytes[quoteAt + 1] == quote
            && bytes[quoteAt + 2] == quote
          let end = quoteAt + (multiline ? 3 : 1)
          code.append(contentsOf: bytes[index..<end])
          index = end
          stack[stack.count - 1].mode = .string(hashes: hashCount, multiline: multiline)
        } else if byte == openParen {
          stack[stack.count - 1].parentheses += 1
          code.append(byte)
          index += 1
        } else if byte == closeParen {
          code.append(byte)
          index += 1
          if stack.count > 1 {
            stack[stack.count - 1].parentheses -= 1
            if stack[stack.count - 1].parentheses == 0 { stack.removeLast() }
          }
        } else {
          code.append(byte)
          index += 1
        }
      }
    }
    if lineStart <= bytes.count, !(lineStart == bytes.count && bytes.last == newline) {
      finishLine(at: bytes.count)
    }
    return lines
  }
}
