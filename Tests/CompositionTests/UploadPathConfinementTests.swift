//  UploadPathConfinementTests
//  A path a client named may only be a file this server handed it.
//
//  `filePath` in a JSON send body was taken verbatim, and the only check anywhere was
//  `FileManager.fileExists`. This process holds Full Disk Access, so an authenticated caller
//  with nothing but `messages:write` could name `chat.db`, a keychain, an SSH key or the
//  server's own `app.db`, have it staged into Messages' container, and have it sent to a chat
//  of their choosing — turning "holds the API password" into "holds the whole disk". The
//  refusal message was a filesystem-existence oracle over every other path besides.
//
//  Confining it breaks no client: `validators/messageValidator.ts:261` in the reference joins
//  `part.attachment` — a NAME — onto a fixed directory, and its routers only ever pass a
//  server-derived `attachmentPath`. The absolute-path door is this server's own addition.
//
//  Two halves here, and the second is the one that lasts. The behaviour tests pin what
//  `confined` does; the source scan pins that every place a client's path enters actually
//  calls it, which is the half a new route would otherwise quietly skip.

import BBAppStore
import BBInterfaces
import BBMedia
import Foundation
import Testing

@testable import BBHandlers

@Suite("Upload path confinement")
struct UploadPathConfinementTests {

  private func store() -> (UploadStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-confine-\(UUID().uuidString)")
    return (UploadStore(directory: root), root)
  }

  @Test("A file inside the upload directory is accepted and returned canonical")
  func acceptsAnUploadedFile() throws {
    let (uploads, root) = store()
    let written = try uploads.write(Data("x".utf8), named: "photo.jpg")
    // The path this server actually hands a client, round-tripped back in.
    #expect(try uploads.confined(written) == UploadStore.canonical(written))
    #expect(try uploads.confined(written).hasPrefix(UploadStore.canonical(root.path)))
  }

  @Test("An absolute path elsewhere on the disk is refused")
  func refusesAnArbitraryPath() throws {
    let (uploads, _) = store()
    // The reachable primitive: a real, readable, sensitive file this process can open.
    for path in [
      "/etc/passwd",
      NSHomeDirectory() + "/Library/Messages/chat.db",
      NSHomeDirectory() + "/Library/Keychains/login.keychain-db",
    ] {
      #expect(throws: (any Error).self) { _ = try uploads.confined(path) }
    }
  }

  @Test("Traversal out of the upload directory is refused")
  func refusesTraversal() throws {
    let (uploads, root) = store()
    // The reason the comparison resolves both sides rather than testing the raw prefix: this
    // string DOES start with the upload directory.
    let escape = root.appendingPathComponent("a/../../../../etc/passwd").path
    #expect(throws: (any Error).self) { _ = try uploads.confined(escape) }
  }

  @Test("A symlink inside the upload directory pointing out of it is refused")
  func refusesSymlinkEscape() throws {
    let (uploads, root) = store()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
    // Lexically under the upload directory; actually not. Only resolving symlinks catches it,
    // and a client can create one of these through any route that writes a name it chooses.
    #expect(throws: (any Error).self) {
      _ = try uploads.confined(link.appendingPathComponent("passwd").path)
    }
  }

  @Test("The refusal names the rule, not the path")
  func refusalIsNotAnOracle() throws {
    let (uploads, _) = store()
    // Two paths that differ in whether they exist must be refused identically, or the error
    // answers "is there a file here?" for anywhere on the disk.
    var messages: Set<String> = []
    for path in ["/etc/passwd", "/etc/definitely-not-a-real-file-\(UUID().uuidString)"] {
      do {
        _ = try uploads.confined(path)
        Issue.record("\(path) should have been refused")
      } catch {
        messages.insert(String(describing: error))
        #expect(!String(describing: error).contains("passwd"))
      }
    }
    #expect(messages.count == 1, "an existing and a missing path must refuse identically")
  }

  // MARK: - The rule the compiler cannot check

  @Test("Every handler that reads a client-named file path confines it")
  func everyClientPathIsConfined() throws {
    // The scan, in the shape the other thirteen policy tests use. A new route that reads
    // `filePath` out of a request body and passes it on is the regression this catches, and
    // it is exactly the shape the original defect had.
    let handlers = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/BBHandlers")

    let files = try FileManager.default
      .contentsOfDirectory(at: handlers, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    // A scan that finds nothing passes while looking exactly like full coverage.
    #expect(files.count > 10, "the handler directory should have been found")

    var offenders: [String] = []
    var confinedSites = 0

    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for (index, line) in source.components(separatedBy: .newlines).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
        // Reading a path OUT of a request: `requireString("filePath"...)`,
        // `part["filePath"]?.stringValue`, `["attachmentPath"]`.
        let readsAPath =
          (trimmed.contains("\"filePath\"") || trimmed.contains("\"attachmentPath\""))
          && (trimmed.contains("requireString") || trimmed.contains("stringValue"))
        guard readsAPath else {
          if trimmed.contains(".confined(") { confinedSites += 1 }
          continue
        }
        // The read is fine as long as the value meets `confined` within a dozen lines: the
        // two are deliberately close together so this can be read locally. Twelve rather than
        // a handful because a `guard` rejecting the missing case sits between them.
        let lines = source.components(separatedBy: .newlines)
        let window = lines[index..<min(index + 12, lines.count)].joined(separator: "\n")
        if window.contains(".confined(") {
          confinedSites += 1
        } else {
          offenders.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
        }
      }
    }

    // Both directions. The floor is what stops this passing because the matcher stopped
    // matching, which is how a scanner silently retires.
    #expect(
      confinedSites >= 2,
      "the scan found \(confinedSites) confined sites; it is not reading the handlers")
    let report = offenders.joined(separator: "\n")
    #expect(
      offenders.isEmpty,
      "a client-named file path reaches a handler without UploadStore.confined:\n\(report)")
  }
}
