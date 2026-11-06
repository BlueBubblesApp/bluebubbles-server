//  AttachmentFilename
//  The one place a client-supplied filename becomes a name on disk.
//
//  A filename here is not decoration: `AttachmentStaging` keeps the last path component of
//  what it copies, and the helper hands that component to IMCore as the transfer's name, so
//  it is exactly what the recipient sees. Clients choose it twice, at upload (the part's
//  `filename`) and at send (`name`), and the send wins. See `UploadStore.renamed(_:to:)`.
//
//  Before this there were two partial cleanups, each replacing `/` and `:` and nothing else.
//  What got through, and what each rule below is for:
//
//    - `..` and `.` became the last component of a path, so the write landed on a DIRECTORY
//      and failed with an error that said nothing about the name. Never an escape, since the
//      component sits inside a fresh UUID directory, but a 500 for a client's typo.
//    - A Windows path stayed whole: `C:\Users\someone\Desktop\x.jpg` reached the recipient
//      with the sender's user name in it. The reference strips through the last backslash
//      (formidable 1.2.6, koa-body 4.2.0's parser: `incoming_form.js:444`), so this matches it.
//    - Bidirectional controls survived, so U+202E could make `gnp.exe` display as `exe.png`.
//      Control characters survived too, newlines included.
//    - Nothing bounded the length, and a name past the file system's limit failed the write.
//
//  What it deliberately does NOT do is check the extension against the content. The sender
//  already chooses the bytes and the name, so a mismatch is theirs to make; and guessing a
//  type from the bytes to second-guess them is a rabbit hole the reference does not enter.

import Foundation

public enum AttachmentFilename {

  /// Used when nothing usable is left. The reference has no equivalent: it would write the
  /// name as given and fail.
  public static let fallback = "attachment"

  /// APFS's limit on one component, in UTF-8 bytes.
  static let maximumBytes = 255

  /// An extension longer than this is not one worth keeping at the expense of the name.
  static let maximumExtensionBytes = 32

  /// Bidirectional formatting characters: the embeddings, overrides and isolates, plus the
  /// marks. Each changes how the REST of the name is displayed rather than adding anything to
  /// it, which is the whole of the extension-spoofing trick.
  static let bidiControls: Set<UInt32> = [
    0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
    0x2066, 0x2067, 0x2068, 0x2069,
  ]

  /// `given` as a single safe path component, or `fallback` when nothing usable is left.
  ///
  /// Every other format character is kept: the zero-width joiner is how a family emoji is
  /// spelled, and a name made of emoji is a legitimate name.
  public static func sanitised(_ given: String, fallback: String = AttachmentFilename.fallback)
    -> String
  {
    let component =
      given.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""

    var scalars = String.UnicodeScalarView()
    for scalar in component.unicodeScalars {
      if scalar.properties.generalCategory == .control { continue }
      if bidiControls.contains(scalar.value) { continue }
      // Finder shows `:` as `/`, and the older cleanups replaced it; kept for both reasons.
      scalars.append(scalar == ":" ? "-" : scalar)
    }
    let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)

    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
    return bounded(cleaned)
  }

  /// Shortened to `maximumBytes`, keeping the extension: the type Messages infers from it
  /// matters more than the tail of the name.
  static func bounded(_ name: String) -> String {
    guard name.utf8.count > maximumBytes else { return name }
    let ext = (name as NSString).pathExtension
    guard !ext.isEmpty, ext.utf8.count <= maximumExtensionBytes else {
      return prefix(of: name, bytes: maximumBytes)
    }
    let stem = (name as NSString).deletingPathExtension
    return prefix(of: stem, bytes: maximumBytes - ext.utf8.count - 1) + "." + ext
  }

  /// The longest run of whole characters that fits, so a cut never splits an emoji.
  private static func prefix(of text: String, bytes: Int) -> String {
    var result = ""
    var used = 0
    for character in text {
      let size = String(character).utf8.count
      guard used + size <= bytes else { break }
      result.append(character)
      used += size
    }
    return result
  }
}
