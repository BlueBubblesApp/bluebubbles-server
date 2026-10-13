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
import BBTestSupport
import Foundation
import Testing

@Suite("Setting keys are not spelled as literals")
struct SettingKeyLiteralTests {

  /// The one file that spells keys freely: the registry, which is where each is declared.
  private static let allowedFiles: Set<String> = [
    "Sources/BBSettings/SettingsRegistry.swift"
  ]

  /// The migration that reads the Electron server's `config.db`. Its rows are the OLD schema
  /// and are named by the strings that database holds, so a declared key may appear there as
  /// a key of `Legacy.rules`, at the start of a line. Nowhere else: a DESTINATION is a typed
  /// setting. Exempting the whole file let `forKey: "connection_method"` through, a write to
  /// a live setting by a spelling nothing checked.
  private static let legacyTableFile = "Sources/BBSettings/LegacyConfigMigration.swift"

  /// Keys that are also wire names, and so appear as literals for a different reason:
  /// `password` is the query parameter and socket credential every client sends, and
  /// `server_address` is a field of `server/info`. A literal of either is the wire, not the
  /// setting.
  private static let wireHomonyms: Set<String> = ["password", "server_address"]

  @Test("No source file outside the registry spells a declared key")
  func noLiteralKeys() throws {
    let keys = Settings.allKeys.filter { !Self.wireHomonyms.contains($0) }
    #expect(keys.count > 20, "the registry looks empty, which would make this test vacuous")
    let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    let literal = try Regex(#""(?:"# + alternatives + #")""#)
    let tableKey = #/^"[a-z0-9_]+":/#

    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 201)
      .filter { !Self.allowedFiles.contains($0.path) }
    let offences = SourceScanner.offences(in: files) { file, line in
      var code = line.code.trimmingCharacters(in: .whitespaces)
      if file.path == Self.legacyTableFile, let key = code.prefixMatch(of: tableKey) {
        code = String(code[key.range.upperBound...])
      }
      return code.contains(literal)
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "setting keys spelled as literals; use `Settings.<name>.key`:\n"
          + offences.report)
    )
  }
}
