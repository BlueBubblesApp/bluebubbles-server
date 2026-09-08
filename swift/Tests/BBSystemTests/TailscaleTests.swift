//  TailscaleTests
//  The Tailscale connection method's arguments, its reading of the daemon, and the waiting
//  state it adds to the coordinator.
//
//  What is asserted is what a user's settings turn into and what the daemon's answers turn
//  into, with no daemon involved: the command lines, because a flag that quietly goes missing
//  is a node that touches this Mac's DNS or listens on the wrong port; the status parsing,
//  because every decision the tunnel makes hangs off five values in a document Tailscale marks
//  "subject to change"; and the coordinator's handling of `awaitingUser`, because getting that
//  wrong restarts the daemon and invalidates the sign-in link a person was just sent.

import BBServiceKit
import Foundation
import Testing

@testable import BBProxy

@Suite("Tailscale arguments")
struct TailscaleArgumentTests {

  private func options(
    exposure: TailscaleOptions.Exposure = .tailnet, port: Int = 443, tls: Bool = false
  ) -> TailscaleOptions {
    TailscaleOptions(
      hostname: "bluebubbles",
      exposure: exposure,
      httpsPort: port,
      originUsesTLS: tls,
      stateDirectory: "/tmp/bb/tailscale",
      socketPath: "/tmp/bb/tailscaled.sock"
    )
  }

  @Test("The daemon runs in userspace, on its own socket and state, without uploading logs")
  func daemonArguments() {
    let arguments = options().daemonArguments
    // Userspace networking is what lets a non-root process run it at all on macOS.
    #expect(arguments.contains("--tun=userspace-networking"))
    #expect(arguments.contains("--socket=/tmp/bb/tailscaled.sock"))
    #expect(arguments.contains("--statedir=/tmp/bb/tailscale"))
    // A random port: the user's own Tailscale may hold the default one.
    #expect(arguments.contains("--port=0"))
    #expect(arguments.contains("--no-logs-no-support"))
    #expect(!arguments.contains("--verbose=1"))

    var chatty = options()
    chatty.sendLogs = true
    chatty.verboseLogging = true
    #expect(!chatty.daemonArguments.contains("--no-logs-no-support"))
    #expect(chatty.daemonArguments.contains("--verbose=1"))
  }

  @Test("Signing in resets preferences, names the machine and touches neither DNS nor routes")
  func upArguments() {
    let arguments = options().upArguments(authKeyFile: nil, timeout: .seconds(15))
    #expect(arguments.first == "up")
    #expect(arguments.contains("--reset"))
    #expect(arguments.contains("--json"))
    #expect(arguments.contains("--hostname=bluebubbles"))
    #expect(arguments.contains("--accept-dns=false"))
    #expect(arguments.contains("--accept-routes=false"))
    #expect(arguments.contains("--timeout=15s"))
    #expect(!arguments.contains { $0.hasPrefix("--auth-key") })
    #expect(!arguments.contains { $0.hasPrefix("--login-server") })
  }

  @Test("An auth key is passed as a file, never as text on the command line")
  func authKeyGoesThroughAFile() {
    let arguments = options().upArguments(authKeyFile: "/tmp/bb/authkey", timeout: .seconds(90))
    #expect(arguments.contains("--auth-key=file:/tmp/bb/authkey"))
    #expect(!arguments.contains { $0.contains("tskey") })
  }

  @Test("A self-hosted control server is passed through")
  func controlServer() {
    var headscale = options()
    headscale.controlURL = " https://headscale.example.test "
    let arguments = headscale.upArguments(authKeyFile: nil, timeout: .seconds(15))
    #expect(arguments.contains("--login-server=https://headscale.example.test"))
  }

  @Test("Tailnet-only serves, Funnel funnels, and both persist in the background")
  func serveArguments() {
    #expect(
      options().serveArguments(forwardingTo: 1234)
        == ["serve", "--bg", "--https=443", "http://127.0.0.1:1234"])
    #expect(
      options(exposure: .funnel, port: 8443).serveArguments(forwardingTo: 1234)
        == ["funnel", "--bg", "--https=8443", "http://127.0.0.1:1234"])
  }

  @Test("The origin scheme follows this server's own TLS setting")
  func originScheme() {
    // `https+insecure` is Tailscale's spelling for "TLS, but do not verify": the
    // certificate on loopback chains to nothing it trusts.
    #expect(options(tls: true).target(port: 1234) == "https+insecure://127.0.0.1:1234")
    #expect(options(tls: false).target(port: 1234) == "http://127.0.0.1:1234")
  }

  @Test("The published address drops the trailing dot and shows a port only when it must")
  func publishedAddress() {
    #expect(
      options().publishedAddress(dnsName: "bluebubbles.tail1234.ts.net.")
        == "https://bluebubbles.tail1234.ts.net")
    #expect(
      options(port: 8443).publishedAddress(dnsName: "bluebubbles.tail1234.ts.net")
        == "https://bluebubbles.tail1234.ts.net:8443")
  }

  @Test("A machine name is reduced to what Tailscale accepts")
  func hostnameSanitising() {
    #expect(TailscaleOptions.sanitisedHostname("BlueBubbles Server") == "bluebubbles-server")
    #expect(TailscaleOptions.sanitisedHostname("  ") == TailscaleOptions.defaultHostname)
    #expect(TailscaleOptions.sanitisedHostname("--Mac's iMessage!!") == "mac-s-imessage")
    #expect(TailscaleOptions.sanitisedHostname(String(repeating: "a", count: 80)).count == 63)
  }
}

@Suite("Reading the Tailscale daemon")
struct TailscaleStatusTests {

  @Test("The five values the tunnel decides on are read out of a status document")
  func parsesStatus() {
    let document = """
      {
        "Version": "1.102.3-t1234",
        "TUN": false,
        "BackendState": "Running",
        "AuthURL": "",
        "TailscaleIPs": ["100.101.102.103"],
        "Self": {
          "ID": "nABCDEFCNTRL",
          "HostName": "bluebubbles",
          "DNSName": "bluebubbles.tail1234.ts.net.",
          "Online": true,
          "CapMap": {"https": null, "funnel": null, "ssh": [{"x": 1}]}
        },
        "CertDomains": ["bluebubbles.tail1234.ts.net"],
        "MagicDNSSuffix": "tail1234.ts.net"
      }
      """
    let status = TailscaleStatus.parse(document)
    #expect(status?.isRunning == true)
    #expect(status?.dnsName == "bluebubbles.tail1234.ts.net")
    #expect(status?.authURL == nil)
    #expect(status?.hasHTTPS == true)
    #expect(status?.hasFunnel == true)
  }

  @Test("A node waiting to be signed in carries its link and no name")
  func parsesNeedsLogin() {
    let document = """
      Warning: something the CLI printed first
      {"BackendState": "NeedsLogin",
       "AuthURL": "https://login.tailscale.com/a/0123456789ab",
       "Self": {"DNSName": "", "CapMap": {}}}
      """
    let status = TailscaleStatus.parse(document)
    #expect(status?.needsLogin == true)
    #expect(status?.authURL?.absoluteString == "https://login.tailscale.com/a/0123456789ab")
    #expect(status?.dnsName == nil)
    #expect(status?.hasHTTPS == false)
  }

  @Test("Something that is not a status document is refused rather than misread")
  func refusesGarbage() {
    #expect(TailscaleStatus.parse("failed to connect to local tailscaled") == nil)
    #expect(TailscaleStatus.parse("{\"Version\": \"1.0\"}") == nil)
  }

  @Test("Which feature the tailnet still has to grant depends on how the server is exposed")
  func missingFeatures() {
    let base = TailscaleOptions(stateDirectory: "/tmp/bb", socketPath: "/tmp/bb.sock")
    var funnel = base
    funnel.exposure = .funnel

    let httpsOnly = TailscaleStatus(backendState: "Running", capabilities: ["https"])
    let both = TailscaleStatus(backendState: "Running", capabilities: ["https", "funnel"])
    let neither = TailscaleStatus(backendState: "Running")

    #expect(!TailscaleCLI.missingFeature(for: base, in: httpsOnly))
    #expect(TailscaleCLI.missingFeature(for: funnel, in: httpsOnly))
    #expect(!TailscaleCLI.missingFeature(for: funnel, in: both))
    #expect(TailscaleCLI.missingFeature(for: base, in: neither))
  }

  @Test("The enabling link is lifted out of whatever the CLI printed around it")
  func findsTheLink() {
    let output = """
      Funnel is not enabled on your tailnet.
      To enable, visit:

               https://login.tailscale.com/f/funnel?node=nABCDEFCNTRL

      """
    #expect(
      TailscaleCLI.firstLink(in: output)?.absoluteString
        == "https://login.tailscale.com/f/funnel?node=nABCDEFCNTRL")
    #expect(TailscaleCLI.firstLink(in: "Available within your tailnet:") == nil)
  }
}

// MARK: - The waiting state

/// A provider that is up but needs a person, and later publishes on its own.
private actor WaitingProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.test.proxy.waiting")
  private(set) var currentAddress: String?
  private var observer: ProxyObserver?
  private(set) var disconnects = 0

  func observe(_ observer: ProxyObserver) async { self.observer = observer }

  func connect() async throws -> String {
    throw ProxyError.awaitingUser(reason: "waiting for you to sign in")
  }

  func disconnect() async {
    disconnects += 1
    currentAddress = nil
  }

  /// The person acted.
  func finish(with address: String) async {
    currentAddress = address
    await observer?.addressChanged(address)
  }
}

private actor Published {
  private(set) var addresses: [String] = []
  func record(_ address: String) { addresses.append(address) }
}

@Suite("A tunnel waiting on a person")
struct AwaitingUserTests {

  @Test("Waiting is not failing: start returns, the reason is reported, nothing restarts")
  func waitingIsNotAFailure() async throws {
    let published = Published()
    let coordinator = ProxyCoordinator(
      onAddressChanged: { address in await published.record(address) }
    )
    let provider = WaitingProvider()

    // Returns rather than throwing, so the registry sees a service that started.
    try await coordinator.start(provider)
    #expect(await coordinator.address == nil)
    #expect(await coordinator.pendingReason == "waiting for you to sign in")
    #expect(await published.addresses.isEmpty)
    // And the provider was not torn down: the daemon behind it holds the sign-in link.
    #expect(await provider.disconnects == 0)

    // The person acts; the provider publishes through the observer installed before
    // `connect()`, and the wait is over.
    await provider.finish(with: "https://bluebubbles.tail1234.ts.net")
    #expect(await published.addresses == ["https://bluebubbles.tail1234.ts.net"])
    #expect(await coordinator.pendingReason == nil)
    #expect(await coordinator.address == "https://bluebubbles.tail1234.ts.net")

    await coordinator.stop()
    #expect(await provider.disconnects == 1)
    #expect(await coordinator.pendingReason == nil)
  }

  @Test("The waiting error is not raised at the user twice")
  func awaitingUserIsNotUserFacing() {
    // The provider has already said what it needs, with a link. A second, generic alert
    // for the same wait would be noise.
    #expect(!ProxyError.awaitingUser(reason: "x").isUserFacing)
    #expect(ProxyError.tunnelFailed(reason: "x").isUserFacing)
  }
}
