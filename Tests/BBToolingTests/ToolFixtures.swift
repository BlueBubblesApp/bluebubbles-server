//  ToolFixtures
//  A vendor, faked at the network boundary and nowhere below it.
//
//  The transport is the only thing stubbed. Everything under it (`tar`, the symlink swap, the
//  digest, the quarantine attribute, running the binary to ask its version) happens for real
//  against real files in a temporary directory, because those are precisely the steps a double
//  would prove nothing about. A mocked filesystem would have told us the installer works and
//  left `tar -xzf` unexercised.

import BBServiceKit
import BBTooling
import Foundation

/// A transport serving canned bytes.
struct StubTransport: ToolTransport, @unchecked Sendable {

  /// URL string → what a GET returns.
  var bodies: [String: Data] = [:]
  /// URL string → headers a HEAD (or a download) reports.
  var headers: [String: [String: String]] = [:]
  var statusCodes: [String: Int] = [:]
  /// URL string → the request headers a fetch or download must carry to be answered, the
  /// way a registry that refuses anonymous requests would insist. Unlisted URLs accept
  /// anything.
  var requiredRequestHeaders: [String: [String: String]] = [:]
  /// Every request header sent, by URL, for asserting what went over the wire.
  let sentHeaders = SentHeaders()

  final class SentHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var byURL: [String: [String: String]] = [:]
    func record(_ headers: [String: String], for url: URL) {
      lock.lock()
      byURL[url.absoluteString] = headers
      lock.unlock()
    }
    subscript(url: String) -> [String: String]? {
      lock.lock()
      defer { lock.unlock() }
      return byURL[url]
    }
  }

  func fetch(_ url: URL, headers: [String: String]) async throws -> (Data, ToolHTTPResponse) {
    sentHeaders.record(headers, for: url)
    guard accepts(headers, for: url) else {
      return (Data(), ToolHTTPResponse(statusCode: 401))
    }
    return (bodies[url.absoluteString] ?? Data(), response(for: url))
  }

  func head(_ url: URL) async throws -> ToolHTTPResponse {
    response(for: url)
  }

  func download(
    _ url: URL,
    to destination: URL,
    headers: [String: String],
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> ToolHTTPResponse {
    sentHeaders.record(headers, for: url)
    guard accepts(headers, for: url) else {
      return ToolHTTPResponse(statusCode: 401)
    }
    progress(0)
    guard let body = bodies[url.absoluteString] else {
      return ToolHTTPResponse(statusCode: 404)
    }
    try body.write(to: destination)
    progress(1)
    return response(for: url)
  }

  private func accepts(_ headers: [String: String], for url: URL) -> Bool {
    guard let required = requiredRequestHeaders[url.absoluteString] else { return true }
    return required.allSatisfy { name, value in headers[name] == value }
  }

  private func response(for url: URL) -> ToolHTTPResponse {
    ToolHTTPResponse(
      statusCode: statusCodes[url.absoluteString] ?? 200,
      headers: headers[url.absoluteString] ?? [:]
    )
  }
}

enum ToolFixtures {

  /// A scratch directory that cleans itself up.
  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-tooling-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A "binary": a shell script that answers a version probe.
  ///
  /// Executable, runnable, and unsigned, which is what makes it usable for the checksum
  /// path and what makes it correctly REFUSED by the signature path.
  static func fakeExecutable(named name: String, version: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let script = """
      #!/bin/sh
      echo "\(name) version \(version)"
      """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  /// Packs a directory's contents into a real `.tar.gz`, using the same `tar` the installer
  /// unpacks with.
  static func tarGzip(contentsOf directory: URL, to archive: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-czf", archive.path, "-C", directory.path, "."]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "ToolFixtures", code: Int(process.terminationStatus))
    }
  }

  static func sha256Hex(of file: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
  }

  /// A GitHub `releases/latest` body.
  static func gitHubRelease(
    tag: String,
    assets: [(name: String, url: String)],
    publishedAt: String = "2026-01-02T03:04:05Z"
  ) -> Data {
    let assetJSON = assets.map { asset in
      """
      {"name": "\(asset.name)", "browser_download_url": "\(asset.url)"}
      """
    }.joined(separator: ",")
    return Data(
      """
      {
        "tag_name": "\(tag)",
        "html_url": "https://github.com/example/example/releases/tag/\(tag)",
        "published_at": "\(publishedAt)",
        "draft": false,
        "prerelease": false,
        "assets": [\(assetJSON)]
      }
      """.utf8)
  }

  /// A tool published as a tarball with checksums and no signature: zrok's shape.
  static func unsignedDescriptor(
    id: String = "faketool",
    executableName: String = "faketool",
    recommended: RecommendedBuild? = nil
  ) -> ManagedToolDescriptor {
    ManagedToolDescriptor(
      id: id,
      displayName: id,
      summary: "A test program.",
      executableName: executableName,
      source: .gitHubReleases(owner: "example", repository: "example"),
      builds: ToolArchitecture.allCases.map { architecture in
        ToolBuild(
          architecture: architecture,
          download: .releaseAsset(
            namePattern: "\(id)_*_darwin_\(architecture == .arm64 ? "arm64" : "amd64").tar.gz"),
          archive: .tarGzip
        )
      },
      signature: .unsigned,
      checksums: .releaseAsset(namePattern: "*checksums*.txt"),
      recommended: recommended,
      versionProbe: VersionProbe(arguments: ["version"], timeoutSeconds: 5)
    )
  }

  /// The asset name the descriptor above will ask for on THIS machine.
  static func assetName(id: String, version: String) -> String {
    let suffix = ToolArchitecture.runnable.first == .arm64 ? "arm64" : "amd64"
    return "\(id)_\(version)_darwin_\(suffix).tar.gz"
  }
}
