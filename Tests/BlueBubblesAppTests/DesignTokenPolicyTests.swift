//  DesignTokenPolicyTests
//  A measurement that has a token is spelled as the token.
//
//  `SettingsMetrics` (`Views/Components/SettingsMetrics.swift`) names the app's corner radii
//  and its sheet sizes by what each is for. A number typed at a call site instead is the
//  shape that drifted into eight radius values and three scaffold widths, and it is invisible
//  in review: `8` reads as a reasonable value wherever it appears. So a literal is refused
//  under `Views/` outside the tokens file. A radius that is genuinely one control's own geometry is a named
//  constant in that control's file, saying what it is relative to (`FloatingBar`), which this
//  scan accepts because it is no longer a bare number at the use site.
//
//  The scans read the source, in the shape of `ViewPlumbingPolicyTests`, whose walker this
//  uses: a SwiftUI view cannot be inspected from a test process without trapping. Comments
//  are skipped.

import BBTestSupport
import Foundation
import Testing

@Suite("Design tokens")
struct DesignTokenPolicyTests {

  /// The one file allowed to spell these numbers.
  private static let tokens = "Components/SettingsMetrics.swift"

  @Test("The tokens file exists and declares the radii the scan points people to")
  func tokensFileIsWhereTheScanSays() throws {
    let source = try SourceScanner.file("\(ViewPlumbingPolicyTests.views)/\(Self.tokens)").code
    // An exemption for a file that has moved exempts nothing, and the remedy below would
    // name a type that is not there.
    for token in ["cardCornerRadius", "tileCornerRadius", "fieldCornerRadius", "rowCornerRadius"] {
      #expect(source.contains("static let \(token)"), "\(Self.tokens) no longer declares \(token)")
    }
    #expect(source.contains("struct SheetSize"), "\(Self.tokens) no longer declares SheetSize")
  }

  @Test("A corner radius under Views/ is a token, never a literal")
  func noLiteralCornerRadius() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views, matching: #"cornerRadius:\s*[0-9]"#, except: [Self.tokens])
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a corner radius is a literal; use `SettingsMetrics.cardCornerRadius`, "
          + "`tileCornerRadius`, `fieldCornerRadius` or `rowCornerRadius`, or name a "
          + "control's own geometry in its file:\n" + offenders.report))
  }

  /// A sheet is framed by a `SheetSize`, through `SheetScaffold(size:)` or `.sheetFrame(_:)`.
  /// The ideal size is what a hand-written sheet `frame` spells: the migration wizard and
  /// onboarding each framed themselves that way, beside the scaffold's two parameters.
  @Test("A sheet's size is a SheetSize, never a literal ideal size")
  func noLiteralSheetSize() throws {
    let offenders = try ViewPlumbingPolicyTests.scan(
      ViewPlumbingPolicyTests.views, matching: #"ideal(Width|Height):\s*[0-9]"#,
      except: [Self.tokens])
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a sheet declares its size in numbers; add or use a `SheetSize` and frame "
          + "the sheet with `.sheetFrame(_:)` or `SheetScaffold(size:)`:\n"
          + offenders.report))
  }
}
