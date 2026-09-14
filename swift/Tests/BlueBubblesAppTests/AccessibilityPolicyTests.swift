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

      for (index, line) in lines.enumerated() where AppSources.opensAControl(line) {
        // The control's own closure, plus the modifiers chained after it:
        // `.accessibilityLabel` is conventionally written there rather than inside.
        let window = AppSources.controlBody(of: lines, from: index)
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

  /// The two spellings a control with a closure-supplied label takes.
  ///
  /// `} label: {` is the explicit form and was the only one checked until an audit pointed
  /// out that the rule in `CLAUDE.md` is broader than the check enforcing it:
  /// `Button(action: x) { Image(…) }` is the same control, written with one trailing closure
  /// instead of two, and was invisible here. There was no offender at the time — both sites
  /// happened to contain a `Text` — which is exactly why it needed closing before there was
  /// one rather than after.
  ///
  /// Deliberately not a general "any SwiftUI control" matcher. These are the forms this app
  /// actually uses, and a matcher for shapes nobody writes reads as coverage it does not have.
  static func opensAControl(_ line: String) -> Bool {
    line.contains("} label: {") || line.contains("Button(action:")
  }

  /// A control's closure and the modifier chain hanging off it.
  ///
  /// Brace-matched rather than a fixed window. The window used to be 24 lines, which is both
  /// arbitrary and wrong in both directions: a card-sized button's body runs past it, so a
  /// `.accessibilityLabel` written after the closing brace fell outside and the control read
  /// as unnamed, while a short control swept up whatever followed it and could be named by
  /// its neighbour's `Text`.
  static func controlBody(of lines: [String], from index: Int) -> String {
    var depth = 0
    var started = false
    var end = index

    for cursor in index..<lines.count {
      // On the opening line of a `} label: {`, counting from the start would see that
      // leading `}` close a brace this control never opened and end the body immediately.
      // Counting from the label's own `{` is what makes the two forms behave the same.
      var line = Substring(lines[cursor])
      if cursor == index, let marker = line.range(of: "} label: {") {
        line = line[marker.lowerBound...].dropFirst("} label: ".count)
      }

      for character in line {
        if character == "{" {
          depth += 1
          started = true
        } else if character == "}" {
          depth -= 1
        }
      }
      end = cursor
      if started && depth <= 0 { break }
    }

    // The chained modifiers, which sit after the closing brace and are where
    // `.accessibilityLabel` conventionally goes.
    //
    // Walking "while the next line starts with a dot" is not enough, and both ways it fails
    // produce a FALSE ACCUSATION, which is the expensive direction for a policy scanner:
    // `.help(…)` wrapped over several lines has continuation lines that start with anything,
    // and a comment between two modifiers has already been blanked to "" by the caller. The
    // notification bell and the read toggle are both named and both were reported as unnamed
    // until this walked the chain properly.
    var tail = end
    var chainDepth = openParenthesisDepth(lines[end])

    while tail + 1 < lines.count {
      let next = lines[tail + 1].trimmingCharacters(in: .whitespaces)
      // Inside a modifier that has not closed its parentheses yet: keep going regardless of
      // how the continuation line happens to start.
      if chainDepth > 0 {
        tail += 1
        chainDepth += openParenthesisDepth(lines[tail])
        continue
      }
      // A blank (or blanked-out comment) only continues the chain when a modifier actually
      // follows it. Consuming blanks unconditionally would run the window into whatever view
      // comes next and let a neighbour's `Text` name this control.
      if next.isEmpty {
        guard
          let following = lines[(tail + 2)...].first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
          }), following.trimmingCharacters(in: .whitespaces).hasPrefix(".")
        else { break }
        tail += 1
        continue
      }
      guard next.hasPrefix(".") else { break }
      tail += 1
      chainDepth += openParenthesisDepth(lines[tail])
    }

    return lines[index...min(tail, lines.count - 1)].joined(separator: "\n")
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

  /// How far a line leaves parentheses open: positive when a modifier spans further lines.
  static func openParenthesisDepth(_ line: String) -> Int {
    line.reduce(into: 0) { depth, character in
      if character == "(" { depth += 1 }
      if character == ")" { depth -= 1 }
    }
  }

  enum PolicyError: Error { case unreadable(String) }
}
