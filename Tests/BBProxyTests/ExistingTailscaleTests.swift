//  ExistingTailscaleTests
//  Reading a Tailscale somebody else runs on this Mac: what it publishes, and which of those
//  addresses are this server's.
//
//  The serve documents below are CONSTRUCTED from Tailscale's `ipn.ServeConfig` type, not
//  recorded from a node: no tailnet was available to record one. `TailscaleServeConfig`'s
//  header says the same. Replace them with a recorded document when there is one.
//
//  The probe runs a real executable: a shell script standing in for the `tailscale` CLI,
//  answering `status` and `serve status` the way the real one does, and a plain file
//  standing in for the socket, which is only ever checked for existence before the CLI is
//  asked.

import Foundation
import Testing

@testable import BBProxy

@Suite("A Tailscale already on this Mac")
struct ExistingTailscaleTests {

  private static let host = "node.example.ts.net"

  private static let servingThisServer = """
    {
      "TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true}},
      "Web": {
        "node.example.ts.net:443": {
          "Handlers": {"/": {"Proxy": "http://127.0.0.1:1234"}}
        },
        "node.example.ts.net:8443": {
          "Handlers": {
            "/": {"Proxy": "http://localhost:9999"},
            "/files": {"Path": "/srv/files"}
          }
        }
      },
      "AllowFunnel": {"node.example.ts.net:8443": true}
    }
    """

  // MARK: - The document

  @Test("Every mount is read, with its address, backend and whether Funnel is on")
  func readsMounts() throws {
    let config = try #require(TailscaleServeConfig.parse(Self.servingThisServer))
    #expect(config.handlers.count == 3)
    let funnel = try #require(config.handlers.first { $0.port == 8443 && $0.path == "/" })
    #expect(funnel.isFunnel)
    #expect(funnel.publishedAddress == "https://\(Self.host):8443")
    let files = try #require(config.handlers.first { $0.path == "/files" })
    #expect(files.proxy == nil)
  }

  @Test("A node that serves nothing is an empty config, not a failure")
  func emptyIsAnAnswer() {
    #expect(TailscaleServeConfig.parse("") == TailscaleServeConfig(handlers: []))
    #expect(TailscaleServeConfig.parse("{}") == TailscaleServeConfig(handlers: []))
    #expect(TailscaleServeConfig.parse("not json at all") == nil)
  }

  @Test("Only a root mount forwarding to this server's port, in its protocol, is its address")
  func whichMountsAreThisServer() throws {
    let config = try #require(TailscaleServeConfig.parse(Self.servingThisServer))
    #expect(
      config.rootHandlers(forwardingToLoopbackPort: 1234, originUsesTLS: false)
        .map(\.publishedAddress) == ["https://\(Self.host)"])
    // The right port in the wrong protocol fails every request, so it is not offered.
    #expect(config.rootHandlers(forwardingToLoopbackPort: 1234, originUsesTLS: true).isEmpty)
    #expect(config.rootHandlers(forwardingToLoopbackPort: 4321, originUsesTLS: false).isEmpty)
  }

  @Test("Each loopback spelling counts, and a host elsewhere does not")
  func loopbackSpellings() {
    func handler(_ proxy: String) -> TailscaleServeConfig.Handler {
      .init(host: Self.host, port: 443, path: "/", proxy: proxy, isFunnel: false)
    }
    #expect(handler("http://127.0.0.1:1234").forwardsToLoopback(port: 1234, originUsesTLS: false))
    #expect(handler("http://localhost:1234").forwardsToLoopback(port: 1234, originUsesTLS: false))
    #expect(handler("http://[::1]:1234").forwardsToLoopback(port: 1234, originUsesTLS: false))
    #expect(
      handler("https+insecure://localhost:1234").forwardsToLoopback(port: 1234, originUsesTLS: true)
    )
    #expect(
      !handler("http://192.0.2.10:1234").forwardsToLoopback(port: 1234, originUsesTLS: false))
  }

  // MARK: - Asking the daemon

  private func fakeCLI(status: String, serve: String?) throws -> (cli: String, socket: String) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-existing-tailscale-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let statusFile = directory.appendingPathComponent("status.json")
    try status.write(to: statusFile, atomically: true, encoding: .utf8)
    let serveFile = directory.appendingPathComponent("serve.json")
    if let serve { try serve.write(to: serveFile, atomically: true, encoding: .utf8) }
    let cli = directory.appendingPathComponent("tailscale")
    // Arguments arrive as `--socket=<path> status …` or `--socket=<path> serve status …`.
    try """
    #!/bin/sh
    case "$2" in
      status) cat "\(statusFile.path)" ;;
      serve) if [ -f "\(serveFile.path)" ]; then cat "\(serveFile.path)"; else echo "boom" >&2; exit 1; fi ;;
    esac
    """.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    let socket = directory.appendingPathComponent("tailscaled.socket")
    try Data().write(to: socket)
    return (cli.path, socket.path)
  }

  private static func status(_ state: String) -> String {
    """
    {"BackendState": "\(state)", "Self": {"DNSName": "\(host).", "HostName": "node",
     "CapMap": {"https": null}}}
    """
  }

  @Test("No socket is nothing, and nothing is run to find that out")
  func noSocketRunsNothing() async throws {
    let found = try await ExistingTailscale.inspect(
      cliPath: "/nonexistent/tailscale", socketPath: "/nonexistent/tailscaled.socket")
    #expect(found == .none)
  }

  @Test("A signed-in node is read with what it publishes")
  func signedInNode() async throws {
    let fake = try fakeCLI(status: Self.status("Running"), serve: Self.servingThisServer)
    let found = try await ExistingTailscale.inspect(cliPath: fake.cli, socketPath: fake.socket)
    guard case .running(let node) = found else {
      Issue.record("expected a running node, got \(found)")
      return
    }
    #expect(node.dnsName == Self.host)
    #expect(node.hasHTTPS)
    #expect(node.serve?.handlers.count == 3)
  }

  @Test("A serve config that cannot be read is unknown, not empty")
  func unreadableServeIsUnknown() async throws {
    let fake = try fakeCLI(status: Self.status("Running"), serve: nil)
    let found = try await ExistingTailscale.inspect(cliPath: fake.cli, socketPath: fake.socket)
    guard case .running(let node) = found else {
      Issue.record("expected a running node, got \(found)")
      return
    }
    #expect(node.serve == nil)
  }

  @Test("A daemon whose node is signed out says so")
  func signedOut() async throws {
    let fake = try fakeCLI(status: Self.status("NeedsLogin"), serve: nil)
    let found = try await ExistingTailscale.inspect(cliPath: fake.cli, socketPath: fake.socket)
    #expect(found == .notRunning(backendState: "NeedsLogin"))
  }
}
