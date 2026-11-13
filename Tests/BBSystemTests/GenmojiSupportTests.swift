//  GenmojiSupportTests
//  The Genmoji decision reads the release and the probe it was given, never the host's.
//
//  The development Mac is macOS 27, and a test process there has no AppKit event loop, so it
//  answers "needs the app" and nothing else: every other cell of the decision is only ever
//  exercised here. The cells that matter most share one creator answer: `notSupported` is
//  "this Mac is not eligible" on 15 and 26 and "use the sheet" on 27, and a wrong split
//  either sends a person to check their region on a Mac that could generate, or tries a
//  hidden window on a Mac whose creator refused for a reason the sheet shares.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import BBSystem

@Suite("Genmoji support decision")
struct GenmojiSupportTests {

  @Test("Below 15.4 is refused on the release alone, without a probe")
  func floor() {
    #expect(
      GenmojiSupport.decide(majorVersion: 14, minorVersion: 6, probe: nil)
        == .releaseTooOld(major: 14, minor: 6))
    #expect(
      GenmojiSupport.decide(majorVersion: 15, minorVersion: 3, probe: nil)
        == .releaseTooOld(major: 15, minor: 3))
    // A probe answer cannot rescue a release that has no API to answer with.
    #expect(
      GenmojiSupport.decide(majorVersion: 15, minorVersion: 1, probe: .ready)
        == .releaseTooOld(major: 15, minor: 1))
  }

  @Test("From 15.4 the probe decides, and a missing probe is said rather than guessed")
  func probeDecides() {
    #expect(
      GenmojiSupport.decide(majorVersion: 15, minorVersion: 4, probe: .ready)
        == .available(.imageCreator))
    #expect(
      GenmojiSupport.decide(majorVersion: 26, minorVersion: 5, probe: .ready)
        == .available(.imageCreator))
    // A 27.x that re-allows the creator goes back to it, whatever the sheet could do.
    #expect(
      GenmojiSupport.decide(majorVersion: 27, minorVersion: 2, probe: .ready, sheet: .ready)
        == .available(.imageCreator))
    #expect(
      GenmojiSupport.decide(majorVersion: 26, minorVersion: 0, probe: .unavailable)
        == .appleIntelligenceUnavailable)
    #expect(
      GenmojiSupport.decide(majorVersion: 26, minorVersion: 0, probe: .unsupportedLanguage)
        == .unsupportedLanguage)
    #expect(
      GenmojiSupport.decide(majorVersion: 26, minorVersion: 0, probe: .failed("xpc"))
        == .undetermined("xpc"))
    if case .undetermined = GenmojiSupport.decide(majorVersion: 26, minorVersion: 0, probe: nil) {
    } else {
      Issue.record("an eligible release with no probe must not claim an answer")
    }
  }

  @Test("notSupported means not eligible before 27, and the sheet decides from 27")
  func notSupportedSplitsOnRelease() {
    // Below 27 the sheet is never consulted: it runs the same model the creator refused.
    for sheet: GenmojiSheetHost? in [nil, .ready, .noEventLoop] {
      #expect(
        GenmojiSupport.decide(majorVersion: 15, minorVersion: 4, probe: .notSupported, sheet: sheet)
          == .deviceNotEligible)
      #expect(
        GenmojiSupport.decide(majorVersion: 26, minorVersion: 5, probe: .notSupported, sheet: sheet)
          == .deviceNotEligible)
    }
    let cells: [(GenmojiSheetHost?, GenmojiSupport)] = [
      (.ready, .available(.playgroundSheet)),
      (.noEventLoop, .needsApp),
      (.imagePlaygroundUnavailable, .appleIntelligenceUnavailable),
      (.broken("the sheet no longer accepts a confirmation"), .withdrawn),
    ]
    for major in [27, 28] {
      for (sheet, expected) in cells {
        #expect(
          GenmojiSupport.decide(
            majorVersion: major, minorVersion: 0, probe: .notSupported, sheet: sheet)
            == expected, "macOS \(major) with \(String(describing: sheet))")
      }
      if case .undetermined = GenmojiSupport.decide(
        majorVersion: major, minorVersion: 0, probe: .notSupported, sheet: nil)
      {
      } else {
        Issue.record("a sheet that was not asked must not be reported as an answer")
      }
    }
  }

  @Test("Every refusal is a sentence naming what decides it, and only availability has none")
  func sentences() {
    let refused: [GenmojiSupport] = [
      .releaseTooOld(major: 14, minor: 6), .withdrawn, .needsApp, .appleIntelligenceUnavailable,
      .deviceNotEligible, .unsupportedLanguage, .undetermined("xpc"),
    ]
    for support in refused {
      #expect(support.refusal != nil, "\(support.reason)")
      #expect(!support.isAvailable)
    }
    for method in [GenmojiMethod.imageCreator, .playgroundSheet] {
      #expect(GenmojiSupport.available(method).refusal == nil)
      #expect(GenmojiSupport.available(method).isAvailable)
      #expect(GenmojiSupport.available(method).method == method)
    }
    // The headless answer names what to do about it.
    #expect(GenmojiSupport.needsApp.refusal?.contains("BlueBubbles app") == true)
    // The two sentences a person acts on name the release that decides.
    #expect(GenmojiSupport.releaseTooOld(major: 14, minor: 6).refusal?.contains("15.4") == true)
    #expect(GenmojiSupport.releaseTooOld(major: 14, minor: 6).refusal?.contains("14.6") == true)
    #expect(GenmojiSupport.withdrawn.refusal?.contains("27") == true)
  }

  @Test("The wire reasons are distinct words")
  func reasons() {
    let all: [GenmojiSupport] = [
      .available(.imageCreator), .releaseTooOld(major: 14, minor: 6), .withdrawn, .needsApp,
      .appleIntelligenceUnavailable, .deviceNotEligible, .unsupportedLanguage,
      .undetermined("xpc"),
    ]
    #expect(Set(all.map(\.reason)).count == all.count)
    for support in all {
      #expect(support.reason.allSatisfy { $0.isLowercase || $0 == "_" }, "\(support.reason)")
    }
  }

  @Test("The real generator reports the host's answer without trapping")
  func hostAnswer() async {
    // Whatever this Mac is, the answer is a decision, not a crash: on the development Mac
    // (27, from a test process with no event loop) it is `needsApp`; on a 15.4 through 26
    // Mac with Apple Intelligence on it is the creator; on Sonoma it is `releaseTooOld`.
    let support = await ImagePlaygroundGenmojiGenerator().support()
    if case .undetermined(let detail) = support {
      Issue.record("Image Playground could not be asked: \(detail)")
    }
    let host = ProcessInfo.processInfo.operatingSystemVersion
    if host.majorVersion >= GenmojiSupport.withdrawnFrom {
      #expect(support == .needsApp)
    }
  }

  @Test("A process with no AppKit event loop is refused the sheet before any window is made")
  func noEventLoopNoWindow() async {
    // The test runner is that process: like the headless server, it never runs NSApplication.
    // The measured failure without a loop was a crash, so the refusal has to come first.
    let host = await PlaygroundSheet.host()
    #expect(host == .noEventLoop)
    #expect(await NSApp == nil || NSApp?.isRunning == false)
  }

  @Test("A sheet that never answers gives up at 45 seconds and suggests rewording")
  func silentSession() {
    // Measured: a declined description produces no callback of any kind, so the deadline is
    // the only way a client hears. Successes took seven to ten seconds.
    #expect(PlaygroundSheet.confirmInterval * PlaygroundSheet.confirmAttempts == .seconds(45))
    #expect(PlaygroundSheet.silentSentence.contains("45 seconds"))
    #expect(PlaygroundSheet.silentSentence.contains("rewording"))
  }

  @Test("The largest strike of a glyph file is the one taken")
  func largestStrike() throws {
    // Three sizes in one HEIC-like container, smallest first, as a glyph orders them.
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 3, nil))
    for side in [40, 320, 96] {
      let context = try #require(
        CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    }
    #expect(CGImageDestinationFinalize(destination))
    let largest = try ImagePlaygroundGenmojiGenerator.largestStrike(of: data as Data)
    #expect(largest.width == 320)
    #expect(largest.height == 320)
    #expect(largest.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  }
}
