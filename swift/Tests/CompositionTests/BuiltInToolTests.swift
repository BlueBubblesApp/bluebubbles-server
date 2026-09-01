//  BuiltInToolTests
//  The shipped tunnel descriptors, checked for the mistakes that are easy to make when bumping
//  one.
//
//  These pins are now a release step: a new cloudflared comes out, someone edits a version
//  string and two digests. Every value in that edit FAILS CLOSED — a mistyped digest refuses
//  every install with a checksum mismatch, a mistyped Team ID refuses it with what reads as
//  tampering — and none of it is exercised until a user presses Install with a live network.
//  So the shape of each value is asserted here, where a typo costs a red test instead of a
//  release.
//
//  What this cannot check is whether a pinned version actually exists or a digest actually
//  matches the vendor's bytes; that needs the network. It checks that whoever edited the file
//  edited all of it — the failure mode of a hand-maintained pin is a version bumped with the
//  digests left behind, which produces a mismatch on the first install and nothing before it.

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
        // 64 lowercase hex characters. A `sha256:` prefix — which is how GitHub's API
        // reports it — would compare unequal against a bare digest and refuse every
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

  @Test("Every declared program belongs to a service that asked to run one")
  func toolsAreReachableFromAManifest() {
    // A descriptor nothing declares is a descriptor nothing installs. The registry is
    // built from the manifests, so an orphan here would be invisible rather than broken —
    // which is the failure this project keeps producing.
    let declared = Set(BuiltInManifests.all.flatMap { $0.tools.map(\.id) })
    for tool in BuiltInTools.all {
      #expect(declared.contains(tool.id), "no manifest declares '\(tool.id)'")
    }
  }
}
