//  Repository
//  Where the checkout is, found once.
//
//  A test that needs a file in the tree (a fixture, a document, the sources a policy test
//  scans) used to climb out of its own `#filePath` with a ladder of
//  `deletingLastPathComponent()` calls, one per directory, each labelled by hand. A ladder
//  is right only for the file it is written in: move the test, or the package, and it points
//  somewhere else without failing, which is how eight hops still read `// swift` after the
//  package moved to the repository root. This file is the one place that knows how deep it
//  sits, and it checks the answer.

import Foundation

public enum Repository {

  /// The repository root: the directory holding `Package.swift`.
  ///
  /// Three levels above this file (`Tests/BBTestSupport/Repository.swift`). Checked rather
  /// than trusted, because a wrong root makes every scan below it empty, and an empty scan
  /// is a policy test that passes having read nothing.
  public static let root: URL = {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // BBTestSupport
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the repository
    precondition(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
      "Repository.root resolved to \(root.path), which holds no Package.swift")
    return root
  }()

  /// A path inside the repository, written relative to the root (`"Sources/BBCore"`).
  public static func url(_ relative: String) -> URL {
    relative.isEmpty ? root : root.appendingPathComponent(relative)
  }

  /// The contents of a file inside the repository.
  public static func read(_ relative: String) throws -> String {
    try String(contentsOf: url(relative), encoding: .utf8)
  }
}
