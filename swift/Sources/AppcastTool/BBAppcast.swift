//  bb-appcast
//  The release pipeline's appcast tool.
//
//  Three jobs, each a step in `swift-release.yml`: sign an artifact, add a release to the
//  feed, and verify a feed before it is published. It exists as a real executable rather than
//  a block of shell in the workflow because every one of these fails silently — a wrong
//  signature or a malformed feed produces a release that looks fine and that no shipped
//  install will ever accept.
//
//  It deliberately does NOT talk to the network or to GitHub. It reads files and writes
//  files, so it can be run by hand against a local artifact when a release goes wrong.
//
//  NOT named main.swift: a file with that name is compiled as top-level code, which cannot
//  coexist with `@main`. `swift build` tolerates it; the Xcode build system used for the
//  universal release build does not, so the failure only appears at packaging time.

import ArgumentParser
import BBCore
import BBUpdates
import Crypto
import Foundation

@main
struct BBAppcast: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bb-appcast",
    abstract: "Sign release artifacts and maintain the Sparkle appcast.",
    subcommands: [Sign.self, Add.self, Verify.self, PublicKey.self]
  )
}

/// Reads the signing key from the environment rather than an argument.
///
/// An argument would put the private key in the process table and in CI logs whenever a
/// command is echoed. Losing this key means shipped installs can never auto-update again,
/// so it is worth the small inconvenience.
private func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
  guard let encoded = ProcessInfo.processInfo.environment["SPARKLE_EDDSA_PRIVATE_KEY"],
    !encoded.isEmpty
  else {
    throw ValidationError(
      "SPARKLE_EDDSA_PRIVATE_KEY is not set. It is read from the environment rather "
        + "than passed as an argument so it does not appear in the process table or in "
        + "CI logs."
    )
  }
  return try AppcastSigning.privateKey(fromBase64: encoded)
}

struct Sign: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Print the base64 Ed25519 signature for a file."
  )

  @Argument(help: "Path to the artifact, usually the DMG.")
  var path: String

  func run() throws {
    let key = try loadPrivateKey()
    let signature = try AppcastSigning.signature(forFileAt: path, privateKey: key)

    // Verified before it is printed. Signing cannot really fail silently, but a key
    // loaded from the wrong secret can, and this is the last cheap place to notice.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
      AppcastSigning.isValid(signature: signature, for: data, publicKey: key.publicKey)
    else {
      throw ValidationError("The signature did not verify against its own key.")
    }
    print(signature)
  }
}

struct Add: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Add a release to the appcast, signing the artifact."
  )

  @Option(help: "Existing appcast to extend. A new one is created if absent.")
  var appcast: String = "appcast.xml"

  @Option(help: "Marketing version, e.g. 1.2.3.")
  var shortVersion: String

  @Option(help: "Build number Sparkle compares. Defaults to the marketing version.")
  var version: String?

  @Option(help: "Path to the DMG.")
  var artifact: String

  @Option(help: "Public download URL for the DMG.")
  var url: String

  @Option(help: "Path to a file of HTML release notes.")
  var notes: String?

  @Option(help: "Minimum macOS version.")
  var minimumSystemVersion: String = "14.0"

  func run() throws {
    let key = try loadPrivateKey()

    guard
      let artifactData = try? Data(
        contentsOf: URL(fileURLWithPath: artifact), options: .mappedIfSafe
      )
    else {
      throw ValidationError("Could not read \(artifact)")
    }
    let signature = try AppcastSigning.signature(for: artifactData, privateKey: key)

    // Extend rather than replace, so history survives. Sparkle uses older entries to
    // present "what changed since your version" across several releases.
    var feed: Appcast
    if let existing = try? Data(contentsOf: URL(fileURLWithPath: appcast)) {
      feed = try AppcastParser.parse(existing)
    } else {
      feed = Appcast(
        title: "BlueBubbles Server",
        link: "https://bluebubbles.app",
        description: "Updates for the BlueBubbles Server."
      )
    }

    // Replacing an existing entry rather than appending a duplicate. Re-running a
    // release for the same version is a normal thing to do after a failed publish, and
    // two entries for one version make Sparkle's choice arbitrary.
    feed.items.removeAll { SemanticVersion($0.shortVersion) == SemanticVersion(shortVersion) }

    feed.items.append(
      AppcastItem(
        shortVersion: shortVersion,
        version: version ?? shortVersion,
        title: shortVersion,
        publishedAt: Date(),
        releaseNotesHTML: notes.flatMap {
          try? String(contentsOfFile: $0, encoding: .utf8)
        },
        downloadURL: url,
        lengthInBytes: artifactData.count,
        edSignature: signature,
        minimumSystemVersion: minimumSystemVersion
      )
    )

    let rendered = feed.xmlString()

    // Re-parsed before it is written. Writing a feed that cannot be read back is the one
    // failure that would reach users, and it costs nothing to rule out here.
    let reparsed = try AppcastParser.parse(Data(rendered.utf8))
    guard reparsed.items.count == feed.items.count else {
      throw ValidationError(
        "The generated appcast does not parse back to \(feed.items.count) items "
          + "(got \(reparsed.items.count)). Refusing to write it."
      )
    }

    try rendered.write(toFile: appcast, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(
      Data(
        "Wrote \(appcast) with \(feed.items.count) item(s); newest is \(shortVersion).\n".utf8
      ))
  }
}

struct Verify: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check that an appcast entry's signature matches an artifact."
  )

  @Option(help: "Appcast to check.")
  var appcast: String = "appcast.xml"

  @Option(help: "Artifact the newest entry should describe.")
  var artifact: String

  @Option(help: "Base64 public key, as embedded in the app's SUPublicEDKey.")
  var publicKey: String

  func run() throws {
    let key = try AppcastSigning.publicKey(fromBase64: publicKey)
    let feed = try AppcastParser.parse(
      try Data(contentsOf: URL(fileURLWithPath: appcast))
    )
    guard let newest = feed.newestItem else {
      throw ValidationError("\(appcast) has no items.")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: artifact), options: .mappedIfSafe)

    guard newest.lengthInBytes == data.count else {
      throw ValidationError(
        "Length mismatch: the appcast says \(newest.lengthInBytes) bytes, "
          + "\(artifact) is \(data.count). Sparkle rejects a size mismatch."
      )
    }
    guard AppcastSigning.isValid(signature: newest.edSignature, for: data, publicKey: key) else {
      throw ValidationError(
        "The signature on \(newest.shortVersion) does not verify against that public "
          + "key. Shipped installs would silently refuse this update."
      )
    }
    print("\(newest.shortVersion) verifies (\(data.count) bytes).")
  }
}

struct PublicKey: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "public-key",
    abstract: "Print the public key for SPARKLE_EDDSA_PRIVATE_KEY, for SUPublicEDKey."
  )

  func run() throws {
    print(AppcastSigning.publicKeyBase64(for: try loadPrivateKey()))
  }
}
