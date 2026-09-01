//  BuiltInTools
//  The three tunnel binaries, described the way a plugin would have to describe one.
//
//  Everything vendor-specific about downloading, verifying and updating ngrok, cloudflared and
//  zrok is in this file and nowhere else. That is the test of whether the model in
//  `ToolRequirement` is real: if managing these three needed anything beyond what a manifest
//  can express, a third-party connection method could never manage its own binary, and we
//  would be back to built-in services having a capability plugins do not.
//
//  They differ in every way they could:
//
//  | | ngrok | cloudflared | zrok |
//  |---|---|---|---|
//  | Published as | one rolling URL per architecture | GitHub releases | GitHub releases |
//  | Version known before download | no | yes | yes |
//  | Packaged as | zip | tar.gz | tar.gz |
//  | Signed by | ngrok, Inc. | Cloudflare Inc. | NetFoundry Inc |
//  | Checksums published | no | in the release notes only | `checksums.sha256.txt` |
//  | Recommended version | not expressible | 2026.8.2 | 1.1.11 |
//
//  **The recommended version is what installs by default**, and it is declared HERE, next to
//  the service that runs the program, because that service is the only thing that knows what it
//  was tested against. Nothing central tracks blessed versions: a registry beside the plugins
//  would be a second place to update, a first place to forget, and something a third-party
//  plugin could never write to. Because it is part of the manifest it travels with whatever
//  ships the plugin — updating the server updates the recommendation, and the next install
//  picks it up. Only the version travels; the bytes are still fetched on demand.
//
//  ngrok has none, and that is not an omission: one URL that always serves the current build
//  offers no way to ask for a particular version. `ManifestValidator` refuses a manifest that
//  recommends a version it could not request, so this asymmetry is stated rather than silently
//  ineffective.
//
//  **Everything below was read off a real download on a real Mac** — the Team IDs from
//  `codesign`, the digests from `shasum -a 256` on the fetched asset, the archive shapes from
//  `tar -tzf`, the version strings from running each binary. None of it is transcribed from
//  documentation, because each of these values fails CLOSED: a wrong Team ID or digest refuses
//  every install with an error indistinguishable from tampering.
//
//  **Bumping a pin is a release step.** A stale pin does not break installs — a version that is
//  no longer published falls back to the current release and says so on the page — but it does
//  mean users quietly get an untested build, which is the thing the pin exists to prevent.
//
//  See `.claude/docs/imessage.md`.

import BBHandlers
import BBInterfaces
import BBServiceKit
import Foundation

public enum BuiltInTools {

  // MARK: - ngrok

  /// Downloaded from ngrok's own stable channel.
  ///
  /// ngrok is not open source and publishes no release list — the documented download is one
  /// URL per platform that always serves the current agent. So there is no version to
  /// compare and no release notes to link: freshness comes from the URL's `ETag`, and the
  /// version is read off the binary after it is installed. That is the honest ceiling on
  /// what this vendor offers, and `.rollingURL` exists to express it rather than to fake
  /// something better.
  ///
  /// The zip contains `ngrok` at its root and nothing else. Verified at 3.39.11, which is
  /// what the stable URL served when this was written — recorded as a note, NOT as a
  /// recommendation, because there is no way to ask for it again.
  public static let ngrok = ManagedToolDescriptor(
    id: "ngrok",
    displayName: "ngrok",
    summary: "The ngrok agent, which opens the tunnel to this server.",
    executableName: "ngrok",
    homepage: URL(string: "https://ngrok.com/download"),
    // No `recommended:`, and it cannot have one — see the note above.
    source: .rollingURL,
    builds: [
      ToolBuild(
        architecture: .arm64,
        download: .url("https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-arm64.zip"),
        archive: .zip
      ),
      ToolBuild(
        architecture: .x86_64,
        download: .url("https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-amd64.zip"),
        archive: .zip
      ),
    ],
    // `Developer ID Application: ngrok, Inc. (TEX8MHRDQ9)`, read from the signature on the
    // agent the stable URL serves. Pinning matters more here than for the other two: a
    // rolling URL has no version and no checksum, so the signature is the ONLY thing
    // standing between this server and whatever that URL happens to serve today.
    signature: .pinnedTeam("TEX8MHRDQ9"),
    versionProbe: VersionProbe(arguments: ["version"])
  )

  // MARK: - cloudflared

  /// Cloudflare's tunnel client, from its GitHub releases.
  ///
  /// The macOS asset is a gzipped tarball containing a single `cloudflared` at its root —
  /// unlike the Linux assets, which are bare binaries. Also the largest of the three by a
  /// wide margin (19 MB compressed, ~38 MB extracted), which is the number that decided this
  /// whole mechanism: bundling it would put that in the app and in every delta update, for a
  /// program most installs never run.
  ///
  /// No checksums asset — Cloudflare publishes digests in the release BODY, as prose. That
  /// is not something to parse, so verification here rests on the signature and on the
  /// pinned digests below.
  public static let cloudflared = ManagedToolDescriptor(
    id: "cloudflared",
    displayName: "cloudflared",
    summary: "Cloudflare's tunnel client, which publishes a trycloudflare.com address.",
    executableName: "cloudflared",
    homepage: URL(string: "https://github.com/cloudflare/cloudflared/releases"),
    source: .gitHubReleases(owner: "cloudflare", repository: "cloudflared"),
    builds: [
      // Exact names rather than patterns: cloudflared's asset names carry no version, so
      // there is nothing for a wildcard to absorb, and a trailing `*` would happily match
      // a signature or metadata file published beside the real one later.
      ToolBuild(
        architecture: .arm64,
        download: .releaseAsset(namePattern: "cloudflared-darwin-arm64.tgz"),
        archive: .tarGzip
      ),
      ToolBuild(
        architecture: .x86_64,
        download: .releaseAsset(namePattern: "cloudflared-darwin-amd64.tgz"),
        archive: .tarGzip
      ),
    ],
    // `Developer ID Application: Cloudflare Inc. (68WVV388M8)`, notarized.
    signature: .pinnedTeam("68WVV388M8"),
    // Digests taken by hashing the downloaded assets, not by trusting the release
    // metadata. They agree with what the API reports; the point of checking was that they
    // might not have.
    recommended: RecommendedBuild(
      version: "2026.8.2",
      digests: [
        "arm64": "9042c2c5d8b2de78e60f313d5fb31b6c5c1cebde787a3caf1f2c9588084ac442",
        "x86_64": "f1727723c586500e2092368ae21871b3df7ddfd2cb097f22d81bee4a9c458bb4",
      ]
    ),
    versionProbe: VersionProbe(arguments: ["--version"])
  )

  // MARK: - zrok

  /// The zrok agent, from the OpenZiti project's GitHub releases.
  ///
  /// **Recommended at 1.1.11 while 2.0.4 is the newest published, and deliberately so.** This
  /// is the case the whole recommended-version mechanism exists for. zrok 2 renamed its
  /// binary to `zrok2` and removed `zrok share reserved` — the subcommand `Tunnels.zrok`
  /// invokes for a reserved share — so installing "the latest" would produce a tunnel that
  /// works for public shares and fails for reserved ones, at runtime, on a machine nobody is
  /// sitting at. 1.1.11 is the newest release the code as written actually drives:
  /// `share public`, `share reserved`, `--headless`, `--backend-mode` and
  /// `--override-endpoint` were all confirmed present in its help output.
  ///
  /// The UI shows 2.0.4 as available and does not push it. Porting to zrok 2's command set
  /// — which replaces `reserve` with `create`/`share public -n` — is tracked in TODO.md, and
  /// when it lands this pin moves with it.
  ///
  /// The asset patterns carry a `*` where the version goes, which is why patterns exist at
  /// all: `zrok_1.1.11_darwin_arm64.tar.gz` would need editing on every release.
  public static let zrok = ManagedToolDescriptor(
    id: "zrok",
    displayName: "zrok",
    summary: "The zrok agent, which shares this server through your zrok environment.",
    executableName: "zrok",
    homepage: URL(string: "https://github.com/openziti/zrok/releases"),
    source: .gitHubReleases(owner: "openziti", repository: "zrok"),
    builds: [
      ToolBuild(
        architecture: .arm64,
        download: .releaseAsset(namePattern: "zrok_*_darwin_arm64.tar.gz"),
        archive: .tarGzip
      ),
      ToolBuild(
        architecture: .x86_64,
        download: .releaseAsset(namePattern: "zrok_*_darwin_amd64.tar.gz"),
        archive: .tarGzip
      ),
    ],
    // `Developer ID Application: NetFoundry Inc (MN5S649TXM)`. zrok's binaries ARE signed,
    // contrary to what this file assumed before anyone looked.
    signature: .pinnedTeam("MN5S649TXM"),
    // Matched loosely because the name has changed across releases — `checksums.txt` and
    // `checksums.sha256.txt` have both been published. Kept alongside the signature: it is
    // the one vendor here that publishes digests as a file, so there is no reason not to
    // check them too.
    checksums: .releaseAsset(namePattern: "*checksums*.txt"),
    recommended: RecommendedBuild(
      version: "1.1.11",
      digests: [
        "arm64": "074ac05b235f22d88eff81168a7b5a11f1b79e975f00f98fd57fc2b81baba440",
        "x86_64": "3bcfee63b4b7b654eb202d5090a3e0f6a3a681edcf1593137db43b094cd61b64",
      ]
    ),
    versionProbe: VersionProbe(arguments: ["version"])
  )

  public static let all: [ManagedToolDescriptor] = [ngrok, cloudflared, zrok]
}
