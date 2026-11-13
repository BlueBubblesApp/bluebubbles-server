//  AttachmentFilenameTests
//  A client-chosen filename becomes one safe path component, and an ordinary one is untouched.
//
//  Both directions matter. The cleanup exists because `..`, a Windows path and a bidi override
//  all got through the old one; but it runs on every name a recipient will see, so a rule that
//  mangled an accented letter or an emoji would be a regression on every send.

import Foundation
import Testing

@testable import BBMedia

@Suite("Attachment filenames")
struct AttachmentFilenameTests {

  @Test(
    "An ordinary name is left exactly as given",
    arguments: [
      "IMG_0001.jpg", "Résumé final.pdf", "voice memo (2).m4a", "👨‍👩‍👧 at the beach.heic",
      ".gitignore",
    ])
  func ordinaryNamesAreUnchanged(name: String) {
    #expect(AttachmentFilename.sanitised(name) == name)
  }

  @Test(
    "A path keeps only its last component, after either separator",
    arguments: [
      ("../../etc/passwd", "passwd"),
      ("photos/2026/beach.jpg", "beach.jpg"),
      // What formidable 1.2.6 does for the reference (`incoming_form.js:444`).
      (#"C:\Users\someone\Desktop\x.jpg"#, "x.jpg"),
      ("trailing/", "trailing"),
    ])
  func pathsAreReducedToAComponent(given: String, expected: String) {
    #expect(AttachmentFilename.sanitised(given) == expected)
  }

  @Test(
    "A name with nothing usable left falls back",
    arguments: ["", ".", "..", "/", #"\"#, "   ", "\u{202E}", "\n\t"])
  func emptyNamesFallBack(given: String) {
    #expect(AttachmentFilename.sanitised(given) == AttachmentFilename.fallback)
    #expect(AttachmentFilename.sanitised(given, fallback: "kept.png") == "kept.png")
  }

  @Test("Bidi controls are removed, so an extension cannot be disguised")
  func bidiControlsAreRemoved() {
    // Displays as `photoexe.png` with the override in place.
    #expect(AttachmentFilename.sanitised("photo\u{202E}gnp.exe") == "photognp.exe")
    #expect(AttachmentFilename.sanitised("a\u{2066}b\u{2069}.txt") == "ab.txt")
  }

  @Test("Control characters are removed and a colon is replaced")
  func controlsAndColons() {
    #expect(AttachmentFilename.sanitised("a\nb\tc\u{0}.jpg") == "abc.jpg")
    #expect(AttachmentFilename.sanitised("10:30 meeting.png") == "10-30 meeting.png")
  }

  @Test("A long name is cut to the file system's limit and keeps its extension")
  func longNamesKeepTheirExtension() {
    let long = String(repeating: "a", count: 300) + ".jpg"
    let bounded = AttachmentFilename.sanitised(long)
    #expect(bounded.utf8.count == AttachmentFilename.maximumBytes)
    #expect(bounded.hasSuffix(".jpg"))
  }

  @Test("A long name is never cut through a character")
  func longNamesCutOnCharacters() {
    // Four UTF-8 bytes each, so 255 is not a multiple and a byte cut would split one.
    let emoji = String(repeating: "🏖", count: 100) + ".png"
    let bounded = AttachmentFilename.sanitised(emoji)
    #expect(bounded.utf8.count <= AttachmentFilename.maximumBytes)
    #expect(bounded.hasSuffix(".png"))
    #expect(bounded.dropLast(4).allSatisfy { $0 == "🏖" })
  }

  @Test("An implausible extension is not kept at the name's expense")
  func longExtensionsAreNotPreserved() {
    let name = "x." + String(repeating: "e", count: 300)
    let bounded = AttachmentFilename.sanitised(name)
    #expect(bounded.utf8.count == AttachmentFilename.maximumBytes)
    #expect(bounded.hasPrefix("x."))
  }
}
