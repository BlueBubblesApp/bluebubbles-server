//  MacPortsArchives
//  Reading MacPorts' binary archives the way `port` does, for a vendor that ships no headless
//  macOS binary of its own.
//
//  Tailscale publishes its daemon for macOS as an App Store or notarized GUI application whose
//  daemon lives inside a system extension and cannot be driven headless. There is no darwin
//  tarball on `pkgs.tailscale.com` and no asset on a GitHub release. What there is, is the
//  open-source daemon as the package managers build it, and MacPorts builds it for every macOS
//  release it supports on BOTH architectures: one archive per version, release and
//  architecture, served from `packages.macports.org` as a plain directory listing, with a
//  signature beside each archive.
//
//  That signature is what makes the source acceptable without a Developer ID signature on the
//  program. It is an Ed25519 signature in OpenBSD's `signify` format over the whole archive,
//  made with MacPorts' archive key, and the public half of that key is compiled in below, so
//  the check rests on something that did not arrive with the download. A server serving
//  different bytes fails closed; so does one serving an archive signed by a key this build
//  does not know, which is what a rotated key looks like until a release carries the new one.
//
//  Three things about the server are not obvious:
//    - It keeps only the last few versions of a port. A recommended version is gone within
//      weeks of the next release, so falling back to the newest is a normal path here rather
//      than an exceptional one. It is still reported, as every fallback is.
//    - Its builders run per macOS release and per architecture and do not finish together:
//      the newest version can have an Apple Silicon archive for every release and an Intel
//      one for only the oldest, or none yet. "Latest" therefore means the newest version
//      with an archive THIS Mac can run, not the newest version listed.
//    - An archive is the port's whole install tree (`opt/local/bin/…`, a launchd plist,
//      shell completions) plus MacPorts' own `+CONTENTS` bookkeeping. Nothing in it is
//      installed except the executables the descriptor names; the rest is unpacked into the
//      version directory and never run.
//
//  See `.claude/docs/performance.md`.

import BBCore
import BBServiceKit
import Crypto
import Darwin
import Foundation

// MARK: - One archive

/// One archive in a port's listing, parsed from its file name.
///
/// `tailscale-1.104.4_0.darwin_23.x86_64.tbz2` is port, version, revision, the Darwin release
/// it was built on and the architecture. A name carrying a `+variant` is a non-default build
/// and is not parsed: what the port builds by default is what was measured.
struct MacPortsArchive: Sendable, Equatable {
  let fileName: String
  /// The upstream version, `1.104.4`: what the program reports and what a manifest pins.
  let version: String
  /// MacPorts' rebuild counter for that version. A higher one supersedes a lower one.
  let revision: Int
  /// The Darwin major the archive was built on: 23 for Sonoma.
  let darwinMajor: Int
  let architecture: ToolArchitecture

  static let fileExtension = ".tbz2"

  static func parse(_ fileName: String, port: String) -> MacPortsArchive? {
    let prefix = "\(port)-"
    guard fileName.hasPrefix(prefix), fileName.hasSuffix(fileExtension),
      !fileName.contains("+"), !fileName.contains("/")
    else { return nil }
    let body = fileName.dropFirst(prefix.count).dropLast(fileExtension.count)

    // From the right, because the version is the one part that contains dots of its own.
    var parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3,
      let architecture = ToolArchitecture(rawValue: parts.removeLast())
    else { return nil }
    let platform = parts.removeLast()
    guard platform.hasPrefix("darwin_"), let darwin = Int(platform.dropFirst("darwin_".count))
    else { return nil }

    let versionAndRevision = parts.joined(separator: ".")
    guard let separator = versionAndRevision.lastIndex(of: "_"),
      let revision = Int(versionAndRevision[versionAndRevision.index(after: separator)...])
    else { return nil }
    let version = String(versionAndRevision[..<separator])
    // A version starts with a digit. Without this, `faketool-extras-1.0_0…` reads as
    // version `extras-1.0` of `faketool`.
    guard version.first?.isNumber == true else { return nil }

    return MacPortsArchive(
      fileName: fileName, version: version, revision: revision, darwinMajor: darwin,
      architecture: architecture)
  }
}

// MARK: - A port's listing

/// Every default-variant archive the server holds for one port.
struct MacPortsListing: Sendable, Equatable {
  let archives: [MacPortsArchive]

  /// Reads the archive names out of the server's directory listing.
  ///
  /// The listing is an ordinary HTML index, so the names are taken from its links rather
  /// than from a document model of the page: anything that is not an archive name for this
  /// port fails `MacPortsArchive.parse` and is ignored, which is what keeps a change to the
  /// page's layout from becoming a change to what is installed.
  static func parse(_ html: String, port: String) -> MacPortsListing {
    var names = Set<String>()
    for chunk in html.components(separatedBy: "href=\"").dropFirst() {
      guard let end = chunk.firstIndex(of: "\"") else { continue }
      names.insert(String(chunk[..<end]))
    }
    let archives = names.compactMap { MacPortsArchive.parse($0, port: port) }
    return MacPortsListing(archives: archives.sorted { $0.fileName < $1.fileName })
  }

  /// The archive of `version` a Mac of this architecture and Darwin release should install.
  ///
  /// The newest revision of the version, and of that revision the archive built on the
  /// OLDEST Darwin release that is no newer than this Mac's. Oldest, because a program built
  /// on an older macOS runs on every newer one, and because it makes the choice depend on
  /// what the server carries rather than on which Mac is asking. No newer than this Mac's,
  /// because the reverse is not promised.
  func archive(
    version: String, architecture: ToolArchitecture, hostDarwinMajor: Int
  ) -> MacPortsArchive? {
    let usable = archives.filter {
      $0.version == version && $0.architecture == architecture
        && $0.darwinMajor <= hostDarwinMajor
    }
    guard let revision = usable.map(\.revision).max() else { return nil }
    return
      usable
      .filter { $0.revision == revision }
      .min { $0.darwinMajor < $1.darwinMajor }
  }

  /// The newest version with an archive this Mac can run, and that archive.
  ///
  /// Not simply the newest version listed: MacPorts' builders do not finish together, and a
  /// version whose Intel build has not landed yet is not an update an Intel Mac can take.
  func newest(architecture: ToolArchitecture, hostDarwinMajor: Int) -> MacPortsArchive? {
    let versions = Set(archives.map(\.version)).sorted {
      SemanticVersion($0) > SemanticVersion($1)
    }
    for version in versions {
      if let found = archive(
        version: version, architecture: architecture, hostDarwinMajor: hostDarwinMajor)
      {
        return found
      }
    }
    return nil
  }
}

// MARK: - The server

/// MacPorts' package server, addressed by port.
struct MacPortsRepository: Sendable {

  static let host = "packages.macports.org"

  let port: String
  private let transport: any ToolTransport

  init(port: String, transport: any ToolTransport) {
    self.port = port
    self.transport = transport
  }

  var listingURL: URL? { URL(string: "https://\(Self.host)/\(port)/") }

  /// Every archive the server holds for this port.
  func listing(toolID: String) async throws -> MacPortsListing {
    guard let url = listingURL else {
      throw ToolError.releaseLookupFailed(tool: toolID, reason: "bad port name")
    }
    let (data, response) = try await transport.fetch(url)
    guard response.isSuccess else {
      throw ToolError.releaseLookupFailed(
        tool: toolID, reason: "MacPorts' package server answered \(response.statusCode)"
      )
    }
    return MacPortsListing.parse(String(decoding: data, as: UTF8.self), port: port)
  }

  func downloadURL(for archive: MacPortsArchive) -> URL? {
    listingURL?.appendingPathComponent(archive.fileName)
  }

  func signatureURL(for archive: MacPortsArchive) -> URL? {
    listingURL?.appendingPathComponent(archive.fileName + ".sig")
  }

  /// The page a person reads about the port on.
  var portPage: String { "https://ports.macports.org/port/\(port)/" }

  /// The key MacPorts signs its binary archives with.
  ///
  /// `keys/archives/macports-archives-2025.pub` in MacPorts' own base repository, which is
  /// the file `port` itself verifies archives with. The year is in the name because MacPorts
  /// rotates it; an archive signed by a successor fails with the successor's name in the
  /// reason, and the remedy is adding it here in a release, never accepting it at runtime.
  static let archiveKeys: [SignifyPublicKey] = [
    SignifyPublicKey(
      name: "macports-archives-2025.pub",
      base64: "RWR+PhirBCclQlM0Khae0up57K9Yy8hRstG1AOyawt/HIIGMckQQWlKn"
    )
  ].compactMap { $0 }

  /// This Mac's Darwin major: 23 on Sonoma. Read from the kernel rather than mapped from the
  /// marketing version, because that mapping is Apple's to change and has.
  static let hostDarwinMajor: Int = {
    var info = utsname()
    guard uname(&info) == 0 else { return .max }
    let release = withUnsafePointer(to: &info.release) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
        String(cString: $0)
      }
    }
    return release.split(separator: ".").first.flatMap { Int($0) } ?? .max
  }()
}

// MARK: - signify

/// An Ed25519 public key in OpenBSD `signify` format, the one MacPorts publishes.
///
/// The decoded key is 42 bytes: the algorithm `Ed`, an eight-byte key number, and the 32-byte
/// key. The key number is what a signature names its key by.
public struct SignifyPublicKey: Sendable, Equatable {
  /// The file name the key is published under, for the sentence explaining a refusal.
  public let name: String
  let keyNumber: Data
  let key: Data

  public init?(name: String, base64: String) {
    guard let decoded = Data(base64Encoded: base64), decoded.count == 42,
      decoded.prefix(2) == Data("Ed".utf8)
    else { return nil }
    self.name = name
    self.keyNumber = decoded.subdata(in: 2..<10)
    self.key = decoded.subdata(in: 10..<42)
  }
}

/// The check an installer runs on a downloaded archive before unpacking it.
public struct ArchiveSignature: Sendable, Equatable {
  /// Where the detached signature is published.
  public let url: URL
  /// The keys an archive may be signed by. Never from the network.
  public let trustedKeys: [SignifyPublicKey]

  public init(url: URL, trustedKeys: [SignifyPublicKey]) {
    self.url = url
    self.trustedKeys = trustedKeys
  }
}

enum Signify {

  /// Why a signature was refused, as the end of a sentence about the download.
  struct Refusal: Error, Equatable {
    let reason: String
  }

  /// Checks a detached `signify` signature over the whole of `file`.
  ///
  /// The file is memory-mapped rather than read: Ed25519 signs the message itself rather than
  /// a digest of it, so the whole archive has to be presented at once, and a mapping keeps
  /// that from being 33 MB of resident memory.
  static func verify(
    _ file: URL, signatureFile text: String, trustedKeys: [SignifyPublicKey]
  ) throws(Refusal) {
    // Two lines: an `untrusted comment:` naming the key, and the base64 signature. The
    // comment is used only to word a refusal; which key applies comes from the key number.
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard lines.count >= 2, lines[0].hasPrefix("untrusted comment:"),
      let decoded = Data(base64Encoded: lines[1]), decoded.count == 74,
      decoded.prefix(2) == Data("Ed".utf8)
    else {
      throw Refusal(reason: "the archive's signature file could not be read")
    }
    let keyNumber = decoded.subdata(in: 2..<10)
    let signature = decoded.subdata(in: 10..<74)

    guard let trusted = trustedKeys.first(where: { $0.keyNumber == keyNumber }) else {
      let named = lines[0].split(separator: " ").last.map(String.init) ?? "an unknown key"
      throw Refusal(
        reason: "the archive is signed with \(named), which this version of BlueBubbles "
          + "does not trust; an update to BlueBubbles is needed to install it")
    }
    let key: Curve25519.Signing.PublicKey
    do {
      key = try Curve25519.Signing.PublicKey(rawRepresentation: trusted.key)
    } catch {
      throw Refusal(reason: "\(trusted.name) is not a usable key")
    }
    let message: Data
    do {
      message = try Data(contentsOf: file, options: .alwaysMapped)
    } catch {
      throw Refusal(reason: "the download could not be read")
    }
    guard key.isValidSignature(signature, for: message) else {
      throw Refusal(reason: "the archive does not match the signature MacPorts published for it")
    }
  }
}
