//  AccessibilityPolicyTests
//  Every control a person can operate has a name, enforced instead of asked for.
//
//  A SwiftUI control is accessible by construction when its label contains text:
//  `Button("Remove")` and `Label("Refresh", systemImage:)` both announce themselves, and most
//  of this app is already written that way. The one shape that fails silently is a control
//  whose label is only an image: it renders perfectly, it has a tooltip on hover, and to
//  VoiceOver it is an unnamed button. A tooltip is not a substitute: it needs a pointer, which
//  is exactly what the person who needs the name does not have.
//
//  An audit found one of these, on the notification bell, and it had been there since the bell
//  was written. Nothing catches that in review: the code reads fine, and the failure is only
//  visible to someone running a screen reader, which is not how this app gets tested.
//
//  So it is checked here, in the shape `TestDataPolicyTests` established: read the sources,
//  assert the rule.
//
//  This deliberately checks ONE thing rather than trying to score accessibility generally.
//  Whether a row should be combined into a single element, or a value announced separately
//  from its name, are judgements no scanner can make. "A control that a person can press has a
//  name" is not a judgement.

import Foundation
import Testing

@Suite("Accessibility policy")
struct AccessibilityPolicyTests {

  @Test("No control has an image for a label and nothing to announce")
  func everyControlIsNamed() throws {
    var unnamed: [String] = []

    for file in try AppSources.swiftFiles() {
      // Comment lines are dropped before scanning. Without that, commenting a label out
      // still satisfied the check, which is exactly the edit someone makes while
      // debugging and forgets to undo.
      let lines = try String(contentsOf: file, encoding: .utf8).split(
        separator: "\n", omittingEmptySubsequences: false
      ).map(String.init).map { line in
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : line
      }

      for (index, line) in lines.enumerated() where line.contains("} label: {") {
        // The label closure, plus the modifiers chained after the control it belongs to:
        // `.accessibilityLabel` is conventionally written there rather than inside.
        let window = lines[index..<min(index + 24, lines.count)].joined(separator: "\n")
        let announces =
          window.contains("Text(")
          || window.contains("Label(")
          || window.contains("accessibilityLabel")
        if !announces {
          unnamed.append("\(AppSources.label(file)):\(index + 1)")
        }
      }
    }

    #expect(
      unnamed.isEmpty,
      """
      These controls have an image for a label and no accessible name. Add
      `.accessibilityLabel("…")`, naming the ACTION, as the button does for a sighted
      user, or give the label text:

      \(unnamed.joined(separator: "\n"))
      """
    )
  }
}

// MARK: - Reading the tree

private enum AppSources {

  /// The app's own sources. Only this target: the rule is about SwiftUI controls, and
  /// nothing outside the app builds one.
  static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // BlueBubblesAppTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Sources/BlueBubblesApp")
  }

  static func label(_ url: URL) -> String {
    url.path.replacingOccurrences(of: root.path + "/", with: "")
  }

  static func swiftFiles() throws -> [URL] {
    guard
      let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      throw PolicyError.unreadable(root.path)
    }
    var files: [URL] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      files.append(url)
    }
    // A rule enforced against nothing is a rule that passes for the wrong reason.
    guard !files.isEmpty else { throw PolicyError.unreadable(root.path) }
    return files.sorted { $0.path < $1.path }
  }

  enum PolicyError: Error { case unreadable(String) }
}
