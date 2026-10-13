//  ToolScriptTests
//  Every script a person runs loads `.env`, and the loader stays safe to point at one.
//
//  A `.env` file is a convention, not a shell feature. Nothing reads it unless a script is
//  written to read it, and the failure is silent in the direction that costs the most:
//  `Tools/dev-bundle.sh` resolves `${DEV_SIGNING_IDENTITY:--}` and treats the fallback as
//  "sign ad-hoc", so a script that forgot to load the file still builds, still succeeds, and
//  invalidates every TCC grant the app had — Full Disk Access, Automation, Contacts — with
//  nothing in the output a reader would stop at.
//
//  That is the whole reason this is a test and not a note in CONTRIBUTING.md: the next script
//  added under `Tools/` or `Packaging/` inherits the behaviour only if someone remembers, and
//  the thing that goes wrong when they do not is invisible.

import BBTestSupport
import Foundation
import Testing

@Suite("Tool scripts")
struct ToolScriptTests {

  /// Scripts that are RUN, as distinct from the two that are only ever sourced.
  ///
  /// A shebang is the discriminator, and it is the file's own statement about which it is:
  /// `dotenv.sh` and `private-api/lib.sh` both open with a comment saying they are sourced
  /// and never run, and neither carries one. The scanner skips hidden directories, so the
  /// `.build` of a checkout that has built the vendored probe, and someone else's scripts
  /// inside it, are never read.
  private func executableScripts() throws -> [(path: String, source: String)] {
    try SourceScanner.files(under: ["Tools", "Packaging"], extensions: ["sh"])
      .filter { $0.text.hasPrefix("#!") }
      .map { ($0.path, $0.text) }
  }

  /// Scripts that deliberately do not load `.env`, each with the reason.
  ///
  /// A list rather than a silent skip, because "this one does not need it" and "nobody got to
  /// this one" are the same absence otherwise.
  private let exempt: [String: String] = [
    "Tools/private-api/dump-headers-vm.sh":
      "Runs inside a macOS VM, from the share `vm-share.sh` builds, where there is no "
      + "checkout and no `.env` to read. It refuses to run from the repository at all — it "
      + "dies if `lib.sh` is beside it — so the load would be dead code where it executes."
  ]

  @Test("Every script a person runs loads .env")
  func scriptsLoadDotenv() throws {
    let scripts = try executableScripts()
    // A scan with no floor reports success when it stops matching. Fifteen scripts exist
    // today; ten is a floor that a real deletion would have to pass before this goes quiet.
    #expect(
      scripts.count >= 10,
      "found only \(scripts.count) runnable scripts; the walk is broken, not the tree")

    for script in scripts {
      if let reason = exempt[script.path] {
        #expect(reason.count > 40, "\(script.path) is exempt for no stated reason")
        #expect(
          !script.source.contains("dotenv.sh"),
          "\(script.path) is listed as exempt but loads .env; delete the exemption")
        continue
      }
      // Either directly, or through `private-api/lib.sh`, which loads it for the seven
      // scripts that source it. `contains` on the bare name would also match the guard in
      // `dump-headers-vm.sh`, which TESTS for lib.sh rather than sourcing it.
      let loadsDirectly = script.source.contains("bb_load_dotenv")
      let loadsViaLibrary = script.source.contains("&& pwd)/lib.sh\"")
      #expect(
        loadsDirectly || loadsViaLibrary,
        """
        \(script.path) does not load `.env`. Source Tools/dotenv.sh and call \
        `bb_load_dotenv` before any `cd`, or add it to `exempt` with the reason. A script \
        that skips this reads no configuration from the file and, if it signs anything, \
        falls back to ad-hoc silently.
        """)
    }
  }

  @Test("The loader reads the working directory, not its own")
  func dotenvReadsTheWorkingDirectory() throws {
    // The distinction the scripts depend on. Five of them `cd` to the repository root as
    // their second statement, so a loader resolving against `${BASH_SOURCE[0]}` would read
    // `Packaging/.env` and `Tools/.env` — neither of which anybody writes — and one
    // resolving after the `cd` would ignore where the person actually stood.
    let code = try loaderCode()
    let readsWorkingDirectory = code.contains("local file=\".env\"")
    #expect(readsWorkingDirectory, "the loader no longer names `.env` relative to the cwd")
    // CODE ONLY. The header explains at length why it does not resolve against
    // `${BASH_SOURCE[0]}`, and a scan that read comments would fail on the sentence saying
    // the right thing — which is the classic way a policy test teaches people to delete the
    // explanation rather than fix the code.
    let resolvesAgainstItself = code.contains("BASH_SOURCE")
    #expect(
      !resolvesAgainstItself,
      "the loader resolves `.env` against its own location; it must use the working directory")
  }

  /// `Tools/dotenv.sh` with its comment lines removed.
  ///
  /// By a `#` prefix rather than through `SourceScanner`'s lexer, which reads Swift: a shell
  /// comment starts with `#`, and `//` means nothing to bash.
  private func loaderCode() throws -> String {
    let text = try Repository.read("Tools/dotenv.sh")
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
      .joined(separator: "\n")
  }

  @Test("The loader never evaluates the file it reads")
  func dotenvDoesNotEval() throws {
    // `.env` is hand-edited and travels between machines, and this one holds a Sparkle
    // signing key and an API key. Expanding `$VAR` with `eval` would also run any `$(…)` in
    // it, so the expansion is done by hand and `$(…)` is emitted literally. Asserted rather
    // than trusted: `eval` is exactly the shortcut someone reaches for when adding a feature
    // to a parser like this one.
    for line in try loaderCode().split(separator: "\n") {
      let statement = line.trimmingCharacters(in: .whitespaces)
      let evaluates = statement.contains("eval ")
      #expect(
        !evaluates,
        "Tools/dotenv.sh evaluates its input: `\(statement)`. Expand variables by hand.")
    }
  }

  @Test("The scripts load .env before changing directory")
  func loadHappensBeforeTheCD() throws {
    // Order is the whole meaning of "from the working directory". `build-app.sh`,
    // `make-dmg.sh`, `notarize-app.sh`, `sign-app.sh` and `dev-bundle.sh` all run
    // `cd "$(dirname "$0")/.."` near the top; loading after it would silently switch the
    // file being read from the caller's directory to the repository root.
    for script in try executableScripts() {
      guard let cd = script.source.range(of: "\ncd \"$(dirname \"$0\")"),
        let load = script.source.range(of: "\nbb_load_dotenv")
      else { continue }
      #expect(
        load.lowerBound < cd.lowerBound,
        """
        \(script.path) loads `.env` after it changes directory, so it reads the repository \
        root's file rather than the one where the command was run.
        """)
    }
  }

  /// The scripts that inject a dylib, each of which must build it through the shared function.
  private static let injectingScripts = [
    "Packaging/build-app.sh",
    "Tools/dev-bundle.sh",
    "Tools/observation-probe/run-probe.sh",
  ]

  /// The second build and its slice check live in `Tools/helper-build.sh` and nowhere else.
  ///
  /// A helper must carry the slices of the app it is injected INTO (`arm64e` on Apple
  /// Silicon), and dyld declines a wrong-slice insert without a word, so the Private API is
  /// simply absent. Three copies of that build and its `lipo` check drift apart, and a weaker
  /// copy fails exactly as quietly as none. This pins the one implementation: every injecting
  /// script calls it, and no other script builds a helper product, names `arm64e` to the
  /// compiler, or runs `lipo` against a dylib.
  @Test("The helper build and its slice check have one implementation")
  func helperBuildIsShared() throws {
    let shared = try codeLines(of: "Tools/helper-build.sh").joined(separator: "\n")
    #expect(shared.contains("bb_build_injected() {"), "helper-build.sh lost bb_build_injected")
    #expect(
      shared.contains("bb_assert_injectable_slices() {"),
      "helper-build.sh lost bb_assert_injectable_slices")
    #expect(
      shared.contains("--product \"$product\""), "helper-build.sh no longer builds per product")
    #expect(shared.contains("lipo -archs"), "helper-build.sh no longer checks slices with lipo")
    #expect(shared.contains("arm64e x86_64"), "the release helpers no longer carry arm64e + x86_64")
    #expect(
      shared.contains("BlueBubblesHelper BlueBubblesFaceTimeHelper"),
      "helper-build.sh no longer builds BOTH helpers")

    for path in Self.injectingScripts {
      let code = try codeLines(of: path).joined(separator: "\n")
      #expect(code.contains("/helper-build.sh\""), "\(path) does not source Tools/helper-build.sh")
      #expect(
        code.contains("bb_build_injected "), "\(path) does not build through bb_build_injected")
    }

    for script in try allScripts() where script.path != "Tools/helper-build.sh" {
      for (number, line) in code(of: script.source) {
        let place = "\(script.path):\(number)"
        let builds = line.contains("swift build")
        #expect(
          !(builds && (line.contains("--product") || line.contains("arm64e"))),
          "\(place) builds a helper itself; call bb_build_injected (Tools/helper-build.sh)")
        #expect(
          !(line.contains("--arch") && line.contains("arm64e")),
          "\(place) passes arm64e by hand; call bb_build_injected (Tools/helper-build.sh)")
        // ANY `lipo`, not only one aimed at a dylib. `build-app.sh` checked the app binary
        // and Sparkle with two hand-written copies of the same loop; a copy is where a
        // weaker match (a substring, so that `arm64e` satisfies `arm64`) gets in.
        #expect(
          !line.contains("lipo"),
          "\(place) checks slices itself; use bb_assert_slices (Tools/helper-build.sh)")
      }
    }
    #expect(
      shared.contains("bb_assert_slices() {"), "helper-build.sh lost bb_assert_slices")
    let release = try codeLines(of: "Packaging/build-app.sh").joined(separator: "\n")
    #expect(
      release.contains("bb_assert_slices \"$BINARY\" arm64 x86_64"),
      "build-app.sh no longer asserts the app binary's slices through bb_assert_slices")
  }

  /// The two scripts that sign a bundle, and the purpose each signs for.
  private static let signingScripts = [
    "Packaging/sign-app.sh": "--purpose release",
    "Tools/dev-bundle.sh": "--purpose development",
  ]

  /// Every bundle is signed by `bb_sign_app` (`Tools/app-signing.sh`) and nothing else.
  ///
  /// `dev-bundle.sh` signed with `codesign --force --deep` and no entitlements, so a dev
  /// bundle had no hardened runtime, no `disable-library-validation` and no profile: it tested
  /// a signature no user runs, and anything only the release signature breaks was first seen
  /// on a user's machine. `--deep` is refused for signing anywhere, because it hands every
  /// nested item the outermost item's entitlements, which is exactly what kills Sparkle's XPC
  /// services and the launcher. Verifying with `--deep` is fine and is how a nested item that
  /// was missed gets caught.
  @Test("Bundles are signed inside-out by one implementation")
  func signingIsShared() throws {
    let shared = try codeLines(of: "Tools/app-signing.sh").joined(separator: "\n")
    #expect(shared.contains("bb_sign_app() {"), "app-signing.sh lost bb_sign_app")
    #expect(shared.contains("--options runtime"), "the shared signer dropped the hardened runtime")
    #expect(
      shared.contains("--entitlements \"$entitlements\""),
      "the shared signer no longer applies the entitlements")
    #expect(
      shared.contains("embedded.provisionprofile"),
      "the shared signer no longer embeds the provisioning profile")
    #expect(
      shared.contains("plutil -remove keychain-access-groups"),
      """
      the shared signer no longer drops keychain-access-groups for an identity the profile \
      does not authorise; an ad-hoc dev bundle claiming it is killed at launch
      """)

    for (path, purpose) in Self.signingScripts {
      let code = try codeLines(of: path).joined(separator: "\n")
      #expect(code.contains("/app-signing.sh\""), "\(path) does not source Tools/app-signing.sh")
      #expect(
        code.contains("bb_sign_app ") && code.contains(purpose),
        "\(path) does not sign through bb_sign_app \(purpose)")
    }

    for script in try allScripts() {
      for (number, line) in code(of: script.source) where line.contains("codesign") {
        let place = "\(script.path):\(number)"
        let verifies = line.contains("--verify") || line.contains("--display")
        #expect(
          verifies || !line.contains("--deep"),
          "\(place) signs with --deep; nested items need different entitlements")
        let signs = line.contains("--sign") || line.contains(" -s ") || line.contains("--force")
        #expect(
          script.path == "Tools/app-signing.sh" || verifies || !signs,
          "\(place) signs a bundle itself; call bb_sign_app (Tools/app-signing.sh)")
      }
    }
  }

  /// Every `.sh` under `Tools/` and `Packaging/`, sourced or run. Ten is a floor well under
  /// the real count, so a walk that broke reads as a failure rather than a clean tree.
  private func allScripts() throws -> [(path: String, source: String)] {
    try SourceScanner.files(under: ["Tools", "Packaging"], extensions: ["sh"], minimum: 10)
      .map { ($0.path, $0.text) }
  }

  /// The non-comment lines of the script at `path`.
  private func codeLines(of path: String) throws -> [String] {
    code(of: try Repository.read(path)).map(\.line)
  }

  /// Non-comment lines with their 1-based line numbers.
  private func code(of text: String) -> [(number: Int, line: String)] {
    text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
      .map { ($0.offset + 1, String($0.element)) }
      .filter { !$0.1.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
  }

  /// The headless CLI is its own bundle, and it needs its own resource bundles.
  ///
  /// `Bundle.main` inside `Helpers/bluebubbles-server.app` is that nested bundle, so the
  /// accessor SwiftPM generates looks in ITS `Contents/Resources` and never in the app's. Both
  /// scripts copied the bundles into the app only, and the documented headless binary aborted
  /// with `fatalError` on the first phone number it parsed. Each script now copies them into
  /// the nested bundle too, and refuses to finish without PhoneNumberKit's there.
  @Test("Both bundle scripts give the nested CLI its own resource bundles")
  func cliBundleCarriesResources() throws {
    for path in ["Packaging/build-app.sh", "Tools/dev-bundle.sh"] {
      let source = try Repository.read(path)
      #expect(
        source.contains(#"cp -R "$resource" "$CLI_APP/Contents/Resources/""#),
        "\(path) does not copy the resource bundles into the CLI bundle")
      #expect(
        source.contains(#""$CLI_APP/Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle""#),
        "\(path) does not check that the CLI bundle carries PhoneNumberKit's resources")
    }
  }
}
