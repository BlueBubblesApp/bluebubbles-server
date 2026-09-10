//  SettingKeyLiteralTests
//  A setting's key is spelled once, in the registry.
//
//  `Settings.x.key` is the only spelling a service, a manifest or a view should use. A key
//  written as a literal compiles, and a renamed setting then silently stops being watched,
//  declared or read; nothing fails until a person notices a switch has no effect. The same
//  shape as `TestDataPolicyTests`: the source tree is scanned, and a hit fails the build.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBSettings
import Foundation
import Testing

@Suite("Setting keys are not spelled as literals")
struct SettingKeyLiteralTests {

  /// Files that legitimately spell keys: the registry itself, and the migration that reads
  /// the Electron server's `config.db`, whose rows are the OLD schema and are named by the
  /// strings that database holds.
  private static let allowedFiles: Set<String> = [
    "Sources/BBSettings/SettingsRegistry.swift",
    "Sources/BBSettings/LegacyConfigMigration.swift",
  ]

  /// Keys that are also wire names, and so appear as literals for a different reason:
  /// `password` is the query parameter and socket credential every client sends, and
  /// `server_address` is a field of `server/info`. A literal of either is the wire, not the
  /// setting.
  private static let wireHomonyms: Set<String> = ["password", "server_address"]

  @Test("No source file outside the registry spells a declared key")
  func noLiteralKeys() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let keys = Settings.allKeys.filter { !Self.wireHomonyms.contains($0) }
    #expect(keys.count > 20, "the registry looks empty, which would make this test vacuous")
    let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    let literal = try Regex(#""(?:"# + alternatives + #")""#)

    var offenders: [String] = []
    for directory in ["Sources", "Helper"] {
      let base = root.appending(path: directory)
      guard let files = FileManager.default.enumerator(atPath: base.path) else { continue }
      for case let relative as String in files where relative.hasSuffix(".swift") {
        let label = directory + "/" + relative
        if Self.allowedFiles.contains(label) { continue }
        let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
          .enumerated()
        {
          let code = line.trimmingCharacters(in: .whitespaces)
          if code.hasPrefix("//") { continue }
          if code.contains(literal) {
            offenders.append("\(label):\(index + 1): \(code)")
          }
        }
      }
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "setting keys spelled as literals; use `Settings.<name>.key`:\n"
          + offenders.joined(separator: "\n"))
    )
  }
}
