//  BuiltInToolTests
//  The shipped tunnel descriptors, checked for the mistakes that are easy to make when bumping
//  one.
//
//  These pins are now a release step: a new cloudflared comes out, someone edits a version
//  string and two digests. Every value in that edit FAILS CLOSED: a mistyped digest refuses
//  every install with a checksum mismatch, a mistyped Team ID refuses it with what reads as
//  tampering, and none of it is exercised until a user presses Install with a live network.
//  So the shape of each value is asserted here, where a typo costs a red test instead of a
//  release.
//
//  What this cannot check is whether a pinned version actually exists or a digest actually
//  matches the vendor's bytes; that needs the network. It checks that whoever edited the file
//  edited all of it: the failure mode of a hand-maintained pin is a version bumped with the
//  digests left behind, which produces a mismatch on the first install and nothing before it.

import BBBuiltIns
import BBServiceKit
import BlueBubblesServerCore
import Foundation
import Testing

@Suite("Built-in tools")
struct BuiltInToolTests {

  @Test("Every shipped program declares something installable")
  func descriptorsAreWellFormed() {
    for tool in BuiltInTools.all {
      #expect(tool.isWellFormed, "\(tool.id) is not a usable identifier")
      #expect(!tool.builds.isEmpty, "\(tool.id) has no builds")
      // Both architectures, because a Mac is one or the other and half the users would
      // otherwise be told the program is not available for their machine.
      let architectures = Set(tool.builds.map(\.architecture))
      #expect(
        architectures == Set(ToolArchitecture.allCases),
        "\(tool.id) is missing a build for \(Set(ToolArchitecture.allCases).subtracting(architectures))"
      )
    }
  }

  @Test("A pinned version pins a digest for every architecture it ships")
  func recommendedVersionsPinEveryDigest() {
    for tool in BuiltInTools.all {
      guard let recommended = tool.recommended else { continue }
      for build in tool.builds {
        // The failure this catches: a version bumped and the digests left behind, or
        // one of the two architectures updated and the other forgotten. Both install
        // fine on the machine the person editing happened to be using.
        #expect(
          recommended.digest(for: build.architecture) != nil,
          "\(tool.id) recommends \(recommended.version) with no \(build.architecture) digest"
        )
      }
    }
  }

  @Test("Pinned digests are SHA-256, not something pasted from the wrong column")
  func digestsAreWellFormed() {
    for tool in BuiltInTools.all {
      for (architecture, digest) in tool.recommended?.digests ?? [:] {
        #expect(
          ToolArchitecture(rawValue: architecture) != nil,
          "\(tool.id) pins a digest for an unknown architecture '\(architecture)'"
        )
        // 64 lowercase hex characters. A `sha256:` prefix (which is how GitHub's API
        // reports it) would compare unequal against a bare digest and refuse every
        // install, so it is caught here rather than there.
        #expect(digest.count == 64, "\(tool.id)'s \(architecture) digest is not 64 characters")
        #expect(
          digest.allSatisfy { $0.isHexDigit && !$0.isUppercase },
          "\(tool.id)'s \(architecture) digest is not lowercase hex"
        )
      }
    }
  }

  @Test("Pinned Team IDs look like Team IDs")
  func teamIdentifiersAreWellFormed() {
    for tool in BuiltInTools.all {
      guard case .pinnedTeam(let team) = tool.signature else { continue }
      // Apple Team IDs are ten uppercase alphanumerics. Anything else is a transcription
      // error, and it refuses every install with a signature error that reads as an
      // attack rather than as a typo.
      #expect(team.count == 10, "\(tool.id) pins a Team ID of the wrong length: '\(team)'")
      #expect(
        team.allSatisfy { $0.isUppercase || $0.isNumber },
        "\(tool.id) pins a malformed Team ID: '\(team)'"
      )
    }
  }

  @Test("A tool that cannot be asked for a version does not recommend one")
  func rollingSourcesHaveNoRecommendation() {
    for tool in BuiltInTools.all where !tool.supportsVersionSelection {
      // ngrok. The validator refuses this combination too; asserted here as well because
      // the tempting fix when someone wants a pin for ngrok is to add one and wonder
      // later why it never applies.
      #expect(
        tool.recommended == nil,
        "\(tool.id) recommends a version its source offers no way to request"
      )
    }
  }

  @Test("A program from a Homebrew bottle asks for bottles, and only bottles")
  func bottleSourcesUseBottleDownloads() {
    // The resolver refuses a bottle source whose build names a release asset, and a GitHub
    // source whose build names a bottle. Both compile; both fail on the first install.
    for tool in BuiltInTools.all {
      let isBottleSource: Bool
      if case .homebrewBottle = tool.source {
        isBottleSource = true
      } else {
        isBottleSource = false
      }
      for build in tool.builds {
        let isBottleDownload: Bool
        if case .homebrewBottle = build.download {
          isBottleDownload = true
        } else {
          isBottleDownload = false
        }
        #expect(
          isBottleSource == isBottleDownload,
          "\(tool.id)'s \(build.architecture) build does not match its source"
        )
      }
    }
  }

  @Test("Tailscale is the daemon, with the CLI declared as its companion")
  func tailscaleInstallsTheDaemon() {
    // The descriptor names the daemon (the thing that is RUN) and declares the CLI as a
    // companion, which is how the tool manager hands `TailscaleMethod` both from one
    // install.
    #expect(BuiltInTools.tailscale.executableName == "tailscaled")
    #expect(BuiltInTools.tailscale.companionExecutables == ["tailscale"])
    #expect(BuiltInTools.tailscale.signature == .unsigned)
    #expect(BuiltInTools.tailscale.recommended != nil)
  }

  // MARK: - The range a copy already on this Mac has to clear

  @Test("Every shipped program says which versions it can drive")
  func everyToolDeclaresARange() {
    // Without one, discovery is OFF for that tool and nothing says so: the server quietly
    // goes on downloading a second copy beside the one the user already has. That is not a
    // validation error — a third-party manifest is entitled to decline — so it is pinned
    // here, for the four we ship.
    for tool in BuiltInTools.all {
      #expect(tool.compatible != nil, "\(tool.id) declares no compatible range")
      #expect(tool.acceptsPreexistingCopies, "\(tool.id) would never use a copy on this Mac")
    }
  }

  @Test("Every declared range can be satisfied")
  func rangesAreCoherent() {
    for tool in BuiltInTools.all {
      guard let range = tool.compatible else { continue }
      #expect(range.isSatisfiable, "\(tool.id)'s range refuses every possible version")
    }
  }

  @Test("A program never recommends a version it would then refuse to use")
  func recommendationsSitInsideTheirRange() {
    // The check that earns the field its keep. Bump zrok's pin to 2.0.4 without moving the
    // ceiling and this goes red here, instead of a tunnel that installs cleanly and then
    // cannot open a reserved share on a machine nobody is sitting at.
    for tool in BuiltInTools.all {
      guard let range = tool.compatible, let recommended = tool.recommended else { continue }
      #expect(
        range.contains(recommended.version),
        "\(tool.id) recommends \(recommended.version), outside \(range.summary)")
    }
  }

  @Test("zrok refuses 2.x, which is the reason ranges exist at all")
  func zrokExcludesTheBreakingMajor() throws {
    // Named specifically rather than left to the general rules above. zrok 2 removed
    // `zrok share reserved`, which `Tunnels.zrok` invokes; the reasoning is recorded in
    // `BuiltInTools.swift` beside the descriptor. Raising this ceiling has to mean someone
    // read that first.
    //
    // `try #require`, not `try? #require`: wrapping a requirement in `try?` turns the one
    // thing it is for -- failing loudly on nil -- into a silent nil, and the strict build
    // rejects it as redundant. A missing range here must fail this test, not skip it.
    let range = try #require(BuiltInTools.zrok.compatible)
    #expect(range.contains("2.0.4") == false)
    #expect(range.contains("2.0.0") == false)
    #expect(range.contains("1.1.11") == true)
  }

  @Test("ngrok has a floor even though it can have no recommended version")
  func ngrokHasAFloorWithoutARecommendation() {
    // The asymmetry the range exists to express: a rolling URL cannot name a version to
    // install, and the code still only drives v3.
    #expect(BuiltInTools.ngrok.recommended == nil)
    #expect(BuiltInTools.ngrok.compatible?.contains("3.18.4") == true)
    #expect(BuiltInTools.ngrok.compatible?.contains("2.3.40") == false)
  }

  @Test("Every declared program belongs to a service that asked to run one")
  func toolsAreReachableFromAManifest() {
    // A descriptor nothing declares is a descriptor nothing installs. The registry is
    // built from the manifests, so an orphan here would be invisible rather than broken:
    // which is the failure this project keeps producing.
    let declared = Set(BuiltInManifests.all.flatMap { $0.tools.map(\.id) })
    for tool in BuiltInTools.all {
      #expect(declared.contains(tool.id), "no manifest declares '\(tool.id)'")
    }
  }
}
