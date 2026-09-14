//  BuiltInTools
//  The four tunnel binaries, described the way a plugin would have to describe one.
//
//  Everything vendor-specific about downloading, verifying and updating ngrok, cloudflared,
//  zrok and Tailscale is in this file and nowhere else. That is the test of whether the model
//  in `ToolRequirement` is real: if managing these four needed anything beyond what a manifest
//  can express, a third-party connection method could never manage its own binary, and we
//  would be back to built-in services having a capability plugins do not.
//
//  They differ in every way they could:
//
//  | | ngrok | cloudflared | zrok | tailscale |
//  |---|---|---|---|---|
//  | Published as | one rolling URL per arch | GitHub releases | GitHub releases | Homebrew bottles |
//  | Version known before download | no | yes | yes | yes |
//  | Packaged as | zip | tar.gz | tar.gz | tar.gz |
//  | Signed by | ngrok, Inc. | Cloudflare Inc. | NetFoundry Inc | nobody (ad hoc) |
//  | Checksums published | no | release notes only | `checksums.sha256.txt` | registry index |
//  | Recommended version | not expressible | 2026.9.1 | 1.1.11 | 1.102.3 |
//  | Copy already on the Mac accepted | >=3, <4 | >=2022.6.1 | >=1.1.11, <2 | >=1.52.0, <2 |
//
//  **The recommended version is what installs by default**, and it is declared HERE, next to
//  the service that runs the program, because that service is the only thing that knows what it
//  was tested against. Nothing central tracks blessed versions: a registry beside the plugins
//  would be a second place to update, a first place to forget, and something a third-party
//  plugin could never write to. Because it is part of the manifest it travels with whatever
//  ships the plugin: updating the server updates the recommendation, and the next install
//  picks it up. Only the version travels; the bytes are still fetched on demand.
//
//  **The last row is a different claim from the one above it, and mixing them up switches this
//  off.** The recommended version is the single build we download; the compatible range is the
//  span of builds whose command surface the code in `Tunnels.swift` and `TailscaleOptions`
//  actually drives, and it is strictly wider. It exists so a copy the user ALREADY has can be
//  used instead of downloading a second one. Deriving its floor from the recommendation would
//  make cloudflared permanently ineligible — no copy on anyone's Mac is ever newer than a
//  CalVer pin on the day it is cut — and cloudflared is the default connection method. Each
//  bound below was measured; a floor fails CLOSED, refusing a copy that works, so it is not a
//  number anyone may reason their way to.
//
//  ngrok has none, and that is not an omission: one URL that always serves the current build
//  offers no way to ask for a particular version. `ManifestValidator` refuses a manifest that
//  recommends a version it could not request, so this asymmetry is stated rather than silently
//  ineffective.
//
//  **Everything below was read off a real download on a real Mac**: the Team IDs from
//  `codesign`, the digests from `shasum -a 256` on the fetched asset, the archive shapes from
//  `tar -tzf`, the version strings from running each binary. None of it is transcribed from
//  documentation, because each of these values fails CLOSED: a wrong Team ID or digest refuses
//  every install with an error indistinguishable from tampering.
//
//  **Bumping a pin is a release step.** A stale pin does not break installs: a version that is
//  no longer published falls back to the current release and says so on the page, but it does
//  mean users quietly get an untested build, which is the thing the pin exists to prevent.
//
//  See `.claude/docs/imessage.md`.

import BBServiceKit
import Foundation

public enum BuiltInTools {

  // MARK: - ngrok

  /// Downloaded from ngrok's own stable channel.
  ///
  /// ngrok is not open source and publishes no release list: the documented download is one
  /// URL per platform that always serves the current agent. So there is no version to
  /// compare and no release notes to link: freshness comes from the URL's `ETag`, and the
  /// version is read off the binary after it is installed. That is the honest ceiling on
  /// what this vendor offers, and `.rollingURL` exists to express it rather than to fake
  /// something better.
  ///
  /// The zip contains `ngrok` at its root and nothing else. Verified at 3.39.11, which is
  /// what the stable URL served when this was written: recorded as a note, NOT as a
  /// recommendation, because there is no way to ask for it again.
  public static let ngrok = ManagedToolDescriptor(
    id: "ngrok",
    displayName: "ngrok",
    summary: "The ngrok agent, which opens the tunnel to this server.",
    executableName: "ngrok",
    homepage: URL(string: "https://ngrok.com/download"),
    // No `recommended:`, and it cannot have one; see the note above.
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
    // v3 only, and the floor is the code's own, not a guess: `NgrokOptions.arguments`
    // emits v3's flag spellings throughout, and records that `--hostname` and `--subdomain`
    // were v2's spelling of a different thing. A v2 agent would take the command line and
    // mean something else by it.
    //
    // The ceiling is a POLICY about a major nobody has run, not a claim about an ngrok 4
    // that does not exist: a major version is where a vendor is entitled to move the
    // command set, and this is the one tool whose source cannot be pinned to a version, so
    // there is nothing else standing between an unseen major and a tunnel that fails to
    // start.
    compatible: ToolVersionRange(atLeast: "3.0.0", below: "4.0.0"),
    versionProbe: VersionProbe(arguments: ["version"])
  )

  // MARK: - cloudflared

  /// Cloudflare's tunnel client, from its GitHub releases.
  ///
  /// The macOS asset is a gzipped tarball containing a single `cloudflared` at its root:
  /// unlike the Linux assets, which are bare binaries. Also the largest of the three by a
  /// wide margin (19 MB compressed, ~38 MB extracted), which is the number that decided this
  /// whole mechanism: bundling it would put that in the app and in every delta update, for a
  /// program most installs never run.
  ///
  /// No checksums asset: Cloudflare publishes digests in the release BODY, as prose. That
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
      version: "2026.9.1",
      digests: [
        "arm64": "c27ab8fd0aa489449e3d201eb02f957ef460a13b613662928b1b23394bf1bcfe",
        "x86_64": "ff0d3b51d5ff70eceef89d6b32145fee985018a2174596a5dbe405e2766e2ac4",
      ]
    ),
    // MEASURED, by downloading each build from Cloudflare's own releases and handing it the
    // exact command line `CloudflareOptions.arguments(forwardingTo:)` produces, in both the
    // quick and the `run` shape, with a deliberately invalid flag as a control to prove the
    // check could detect a refusal at all. Every flag this server emits — `--config`,
    // `--no-autoupdate`, `--logfile`, `--url`, `--protocol`, `--edge-ip-version`, `--region`,
    // `--loglevel`, `--no-tls-verify` — is accepted by every release from 2022.6.1 through
    // 2026.8.2. Note `--protocol` is absent from `tunnel --help` on EVERY build including the
    // one we ship, so reading help text rather than trying the flag would have produced a
    // floor of "newer than everything".
    //
    // So 2022.6.1 is the oldest release tested, not a boundary anyone found: nothing is
    // claimed about older builds except that nobody ran them. Lowering it further is another
    // measurement, not an edit.
    //
    // Worth knowing and deliberately NOT encoded here: `cloudflared-darwin-arm64.tgz` first
    // appears at 2024.8.2, so on Apple Silicon an older copy is an Intel binary. That needs
    // no rule — without Rosetta the version probe's launch fails and the candidate is
    // skipped, which is what `Subprocess.Failure` reports it for.
    compatible: ToolVersionRange(atLeast: "2022.6.1"),
    versionProbe: VersionProbe(arguments: ["--version"])
  )

  // MARK: - zrok

  /// The zrok agent, from the OpenZiti project's GitHub releases.
  ///
  /// **Recommended at 1.1.11 while 2.0.4 is the newest published, and deliberately so.** This
  /// is the case the whole recommended-version mechanism exists for. zrok 2 renamed its
  /// binary to `zrok2` and removed `zrok share reserved`: the subcommand `Tunnels.zrok`
  /// invokes for a reserved share, so installing "the latest" would produce a tunnel that
  /// works for public shares and fails for reserved ones, at runtime, on a machine nobody is
  /// sitting at. 1.1.11 is the newest release the code as written actually drives:
  /// `share public`, `share reserved`, `--headless`, `--backend-mode` and
  /// `--override-endpoint` were all confirmed present in its help output.
  ///
  /// The UI shows 2.0.4 as available and does not push it. Porting to zrok 2's command set
  /// (which replaces `reserve` with `create`/`share public -n`) is tracked in TODO.md under
  /// "Tunnel binaries", and
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
    // Matched loosely because the name has changed across releases: `checksums.txt` and
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
    // The ceiling is the reason this whole field exists, and it is already argued above:
    // zrok 2 removed `zrok share reserved`, which `ZrokOptions.arguments` invokes. A 2.0.4
    // sitting in /opt/homebrew/bin clears any floor and then fails when a reserved share is
    // opened — at runtime, on a machine nobody is sitting at. The floor is the same 1.1.11
    // whose help output was checked for every subcommand and flag this server sends; it is
    // the oldest version anyone has confirmed, not the oldest that works.
    compatible: ToolVersionRange(atLeast: "1.1.11", below: "2.0.0"),
    versionProbe: VersionProbe(arguments: ["version"])
  )

  // MARK: - Tailscale

  /// The open-source Tailscale daemon and CLI, from the bottles Homebrew builds for them.
  ///
  /// Tailscale ships macOS in two forms and neither is this: the App Store and standalone
  /// applications run their daemon inside a network system extension that needs an
  /// administrator to approve and a person to sign in through the menu bar, and there is no
  /// `tailscaled` tarball for darwin on `pkgs.tailscale.com` and no binary on a GitHub
  /// release. What there is, is a Homebrew formula (which is where Tailscale's own
  /// documentation sends anyone wanting the daemon on a Mac) and Homebrew's builders
  /// publish the result to a registry that this server can read without `brew`. The bottle
  /// is a gzipped tarball with `tailscale/<version>/bin/tailscaled` and `bin/tailscale`
  /// beside it; the connection method needs both, and declares the second as a companion.
  ///
  /// **Unsigned, and verified by digest instead.** Homebrew's builders sign ad hoc, which
  /// carries no team and proves nothing about who built it. What stands in is that a bottle
  /// is fetched BY its SHA-256: the registry's index names it, the download is addressed by
  /// it, and the installer hashes what arrived, plus the pin below, which travelled inside
  /// this signed application. A registry serving something else fails closed twice over.
  ///
  /// The digests are the index's `sh.brew.bottle.digest` for 1.102.3's `arm64_sonoma` and
  /// `sonoma` bottles, which are the ones the resolver picks (the oldest macOS each
  /// architecture is built for, since macOS 14 is the floor). They are the values the OCI
  /// layer is addressed by (`ghcr.io/v2/homebrew/core/tailscale/blobs/sha256:<digest>`)
  /// read off the registry rather than off a completed download; a transcription error
  /// refuses every install rather than admitting one.
  ///
  /// `tailscaled --version` prints the version on its first line, which is what the probe
  /// reads; the CLI prints the same.
  public static let tailscale = ManagedToolDescriptor(
    id: "tailscale",
    displayName: "Tailscale",
    summary: "The open-source Tailscale daemon, which joins this Mac to your tailnet.",
    executableName: "tailscaled",
    // The CLI, which the connection method drives the daemon with. Both are made runnable
    // on install and the method asks the tool manager for this one by name.
    companionExecutables: ["tailscale"],
    homepage: URL(string: "https://formulae.brew.sh/formula/tailscale"),
    source: .homebrewBottle(formula: "tailscale"),
    builds: [
      ToolBuild(architecture: .arm64, download: .homebrewBottle, archive: .tarGzip),
      ToolBuild(architecture: .x86_64, download: .homebrewBottle, archive: .tarGzip),
    ],
    signature: .unsigned,
    recommended: RecommendedBuild(
      version: "1.102.3",
      digests: [
        "arm64": "46c67806a1fadef72641f73e214419fbe9589aa96952a7d99d42f0b4393ae23b",
        "x86_64": "30d20988a55dd0afb46fb6e4fa2f64d0885ba6f07d2506872435c40881037aad",
      ]
    ),
    // MEASURED across the formula's published bottles, by fetching each from the same
    // registry the resolver uses, extracting both binaries and handing them the arguments
    // this server actually sends, with a deliberately invalid flag as a control on every
    // run. Three separate floors came out of it, and the CLI's is the binding one:
    //
    //   `tailscaled --statedir`                       1.16.2 refuses it, 1.18.1 accepts
    //   `tailscale up --reset --json --timeout=`      1.18.1 refuses, 1.38.3 accepts
    //   `tailscale serve --bg` / `funnel --bg`        1.50.1 refuses, 1.52.0 accepts
    //
    // So 1.52.0. It is well below the recommended bottle on purpose: the recommendation is
    // the build we install, and this is the span `TailscaleOptions` and `TailscaleCLI` can
    // drive. Pinning the floor to the recommendation instead would refuse almost every
    // Homebrew copy on any Mac that had not updated this week, which is the whole audience.
    //
    // Two things the measurement does NOT cover, stated rather than implied: a flag being
    // accepted is not the daemon working end to end, and `tailscale`'s bogus-SUBCOMMAND
    // error only becomes recognisable at 1.66, so the subcommand probes below that were
    // discarded and only flag-level refusals were counted.
    //
    // The ceiling is the same unseen-major policy as ngrok's.
    compatible: ToolVersionRange(atLeast: "1.52.0", below: "2.0.0"),
    versionProbe: VersionProbe(arguments: ["--version"])
  )

  public static let all: [ManagedToolDescriptor] = [ngrok, cloudflared, zrok, tailscale]
}
