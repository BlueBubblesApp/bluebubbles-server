//  ConversationPickerPolicyTests
//  Every page that chooses a conversation embeds `ConversationPicker`.
//
//  Two copies of "what is this chat called" drift: the composer showed the address beside a
//  contact's name, the export page did not, and a person picking the same chat on two pages
//  saw two different rows. So the list a person picks from is read in exactly one place, the
//  picker, from `ConversationDirectory`; a page holds only the GUIDs it was given. A source
//  scan, in the shape of `ServerStoppedNoticeTests`, because a SwiftUI view cannot be
//  inspected from a test without trapping.

import Foundation
import Testing

@Suite("Conversation picker policy")
struct ConversationPickerPolicyTests {

  @Test("Only ConversationPicker reads the conversation list")
  func onePicker() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BlueBubblesApp")
    // The directory's list, and the chat interface's own reads, which are the two ways a
    // page could assemble a picker of its own.
    let pattern = try Regex(#"conversations\.list\(|\.chat\.query\(|\.chat\.find\("#)

    var offenders: [String] = []
    var scannedFiles = 0
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      scannedFiles += 1
      if relative.hasSuffix("ConversationPicker.swift") { continue }
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        if code.contains(pattern) {
          offenders.append("Sources/BlueBubblesApp/\(relative):\(index + 1): \(code)")
        }
      }
    }
    // A floor, so a walk that finds nothing cannot pass as compliance.
    #expect(
      scannedFiles > 10,
      "scanned only \(scannedFiles) files; this check is not reading the tree")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a page reads conversations for a picker of its own; embed "
          + "`ConversationPicker`:\n" + offenders.joined(separator: "\n"))
    )
  }
}
