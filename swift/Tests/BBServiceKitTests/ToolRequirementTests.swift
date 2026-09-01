//  ToolRequirementTests
//  The rules about a service that downloads and runs someone else's program.
//
//  Two of these checks exist for the user rather than for correctness, and they are the ones
//  worth being strict about. Downloading a binary from the internet and executing it is the
//  most consequential thing anything in this model does, and the permissions list is the only
//  place a person sees it — so a service that fails to declare the entitlement, or names a
//  friendly host and downloads from somewhere else, is refused rather than corrected. The
//  third is about the download: unsigned, unchecksummed bytes are verified by nothing.
//
//  See `docs/EVENTS.md` and `.claude/docs/imessage.md`.

import Foundation
import Testing

@testable import BBServiceKit

@Suite("Declared programs")
struct ToolRequirementTests {

  private static let secrets: Set<String> = ["password"]

  private func tool(
    id: String = "faketool",
    signature: SignaturePolicy = .trustOnFirstUse,
    checksums: ChecksumSource? = nil,
    builds: [ToolBuild]? = nil,
    source: ToolSource = .gitHubReleases(owner: "example", repository: "example")
  ) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: id,
      displayName: id,
      summary: "A program.",
      executableName: id,
      source: source,
      builds: builds ?? [
        ToolBuild(
          architecture: .arm64,
          download: .releaseAsset(namePattern: "\(id)_*_darwin_arm64.tar.gz"),
          archive: .tarGzip
        ),
        ToolBuild(
          architecture: .x86_64,
          download: .releaseAsset(namePattern: "\(id)_*_darwin_amd64.tar.gz"),
          archive: .tarGzip
        ),
      ],
      signature: signature,
      checksums: checksums
    )
  }

  private func manifest(
    tools: [ManagedToolDescriptor],
    entitlements: [Entitlement]
  ) -> ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("app.example.tunnel"),
      name: "Example",
      summary: "A tunnel.",
      category: .reverseProxy,
      entitlements: entitlements,
      tools: tools
    )
  }

  /// Every host a download reaches, declared and shown to the user.
  private var gitHubHosts: [Entitlement] {
    [
      .spawnProcess,
      .network(hosts: [
        "api.github.com", "github.com", "objects.githubusercontent.com",
      ]),
    ]
  }

  @Test("A well-formed declaration passes")
  func validDeclaration() {
    let problems = ManifestValidator.validate(
      manifest(tools: [tool()], entitlements: gitHubHosts), secretKeys: Self.secrets
    )
    #expect(problems.isEmpty)
  }

  @Test("A service that runs a program must say so")
  func spawnProcessIsRequired() {
    // Without this, "downloads and runs a 38 MB program published by someone else" would
    // not appear anywhere the user looks before enabling it.
    let problems = ManifestValidator.validate(
      manifest(
        tools: [tool()],
        entitlements: [
          .network(hosts: [
            "api.github.com", "github.com", "objects.githubusercontent.com",
          ])
        ]
      ),
      secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .toolWithoutSpawnProcess = $0 { true } else { false } })
  }

  @Test("Downloading from a host the service did not declare is refused")
  func downloadHostsMustBeDeclared() {
    let problems = ManifestValidator.validate(
      manifest(
        tools: [tool()],
        // Names a plausible-looking host and downloads from GitHub. This is exactly
        // the shape a misleading permissions list takes.
        entitlements: [.spawnProcess, .network(hosts: ["example.com"])]
      ),
      secretKeys: Self.secrets
    )
    let missing = problems.compactMap { problem -> String? in
      if case .toolHostNotDeclared(_, _, let host) = problem { return host } else { return nil }
    }
    #expect(missing.contains("api.github.com"))
    #expect(missing.contains("objects.githubusercontent.com"))
  }

  @Test("A rolling download's own host has to be declared too")
  func rollingHostsAreDerivedFromTheURL() {
    let rolling = tool(
      builds: [
        ToolBuild(
          architecture: .arm64,
          download: .url("https://bin.example.io/tool-darwin-arm64.zip"),
          archive: .zip
        )
      ],
      source: .rollingURL
    )
    #expect(rolling.networkHosts == ["bin.example.io"])

    let problems = ManifestValidator.validate(
      manifest(tools: [rolling], entitlements: [.spawnProcess]),
      secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .toolHostNotDeclared = $0 { true } else { false } })
  }

  @Test("An unsigned program with no checksums is verified by nothing, and is refused")
  func unsignedNeedsChecksums() {
    let problems = ManifestValidator.validate(
      manifest(tools: [tool(signature: .unsigned)], entitlements: gitHubHosts),
      secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .unverifiableTool = $0 { true } else { false } })

    // With checksums it is acceptable — weaker than a signature, and stated as such in
    // the UI rather than hidden.
    let checked = ManifestValidator.validate(
      manifest(
        tools: [
          tool(
            signature: .unsigned, checksums: .releaseAsset(namePattern: "*checksums*.txt")
          )
        ],
        entitlements: gitHubHosts
      ),
      secretKeys: Self.secrets
    )
    #expect(checked.isEmpty)
  }

  @Test("A tool id that is not safe as a directory name is refused")
  func malformedToolIdentifiers() {
    // The id becomes a path component under Application Support.
    for bad in ["../escape", "with/slash", ""] {
      let problems = ManifestValidator.validate(
        manifest(tools: [tool(id: bad)], entitlements: gitHubHosts),
        secretKeys: Self.secrets
      )
      #expect(
        problems.contains { if case .malformedToolIdentifier = $0 { true } else { false } },
        "'\(bad)' should be refused"
      )
    }
  }

  @Test("A program with no builds could never be installed")
  func toolsNeedBuilds() {
    let problems = ManifestValidator.validate(
      manifest(tools: [tool(builds: [])], entitlements: gitHubHosts),
      secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .toolWithoutBuilds = $0 { true } else { false } })
  }

  @Test("Two builds for the same architecture is a manifest that cannot mean one thing")
  func duplicateArchitectures() {
    let duplicated = tool(builds: [
      ToolBuild(
        architecture: .arm64,
        download: .releaseAsset(namePattern: "a"),
        archive: .tarGzip
      ),
      ToolBuild(
        architecture: .arm64,
        download: .releaseAsset(namePattern: "b"),
        archive: .tarGzip
      ),
    ])
    let problems = ManifestValidator.validate(
      manifest(tools: [duplicated], entitlements: gitHubHosts), secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .duplicateToolBuild = $0 { true } else { false } })
  }

  @Test("Declaring the same program twice is refused")
  func duplicateTools() {
    let problems = ManifestValidator.validate(
      manifest(tools: [tool(), tool()], entitlements: gitHubHosts),
      secretKeys: Self.secrets
    )
    #expect(problems.contains { if case .duplicateTool = $0 { true } else { false } })
  }
}

@Suite("Asset name patterns")
struct GlobPatternTests {

  @Test("A version in the middle of an asset name is matched by a wildcard")
  func matchesVersionedNames() {
    // The case that motivates patterns at all: the version is in the name, so an exact
    // name would need editing on every vendor release.
    #expect(GlobPattern.matches("zrok_*_darwin_arm64.tar.gz", "zrok_1.0.4_darwin_arm64.tar.gz"))
    #expect(!GlobPattern.matches("zrok_*_darwin_arm64.tar.gz", "zrok_1.0.4_darwin_amd64.tar.gz"))
    #expect(!GlobPattern.matches("zrok_*_darwin_arm64.tar.gz", "zrok_1.0.4_linux_arm64.tar.gz"))
  }

  @Test("Leading and trailing wildcards anchor the way a reader expects")
  func anchoring() {
    #expect(GlobPattern.matches("*checksums*.txt", "zrok_1.0.4_checksums.txt"))
    #expect(GlobPattern.matches("*checksums*.txt", "checksums.txt"))
    #expect(!GlobPattern.matches("*checksums*.txt", "checksums.txt.sig"))
    #expect(GlobPattern.matches("cloudflared-darwin-arm64*", "cloudflared-darwin-arm64"))
    #expect(GlobPattern.matches("cloudflared-darwin-arm64*", "cloudflared-darwin-arm64.tgz"))
    #expect(!GlobPattern.matches("cloudflared-darwin-arm64*", "cloudflared-darwin-amd64"))
  }

  @Test("A pattern with no wildcard is an exact name")
  func exactMatch() {
    #expect(GlobPattern.matches("ngrok", "ngrok"))
    #expect(!GlobPattern.matches("ngrok", "ngrok.zip"))
  }
}
