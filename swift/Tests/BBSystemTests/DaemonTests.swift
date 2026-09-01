//  DaemonTests
//  The tunnel supervisor, driven against real processes.
//
//  `/bin/sh` stands in for ngrok. That is not a shortcut — the things worth testing here are
//  process lifecycle and output scraping, and a fake process double would only prove the
//  double behaves as I imagined. A real process that prints and exits exercises the pipe
//  handling, the termination handler, and the readiness race for real.

import BBCore
import BBServiceKit
import BBSystem
import Foundation
import Testing

@testable import BBProxy

/// A daemon that prints the given lines and then waits, or exits.
private func shellDaemon(
  script: String,
  name: String = "test-daemon"
) -> DaemonConfiguration {
  DaemonConfiguration(
    name: name,
    executablePath: "/bin/sh",
    arguments: ["-c", script],
    restartDelay: .milliseconds(10)
  )
}

@Suite("Daemon lifecycle", .serialized)
struct DaemonLifecycleTests {

  /// The core of every tunnel: run a binary, watch its output, pull a URL out.
  @Test("A readiness signal extracts a value from the output")
  func readinessExtractsValue() async throws {
    let daemon = DaemonProcess(
      configuration: shellDaemon(
        script: "echo 'starting up'; echo 'url=https://example.ngrok-free.app'; sleep 20"
      )
    )
    let signal = ReadinessSignal(timeout: .seconds(10)) { line in
      guard let range = line.range(of: "url=") else { return nil }
      return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    let url = try await daemon.start(waitingFor: signal)
    #expect(url == "https://example.ngrok-free.app")
    #expect(await daemon.isRunning)
    await daemon.stop()
  }

  /// A tunnel binary that dies before printing a URL has failed to start, and its own
  /// output is the only useful explanation anyone will get — "exited with 1" is not one.
  @Test("An early exit surfaces the daemon's own output")
  func earlyExitCarriesOutput() async {
    let daemon = DaemonProcess(
      configuration: shellDaemon(
        script: "echo 'ERR_NGROK_108: your authtoken is invalid' >&2; exit 1"
      )
    )
    let signal = ReadinessSignal(timeout: .seconds(10)) { line in
      line.contains("url=") ? line : nil
    }

    do {
      _ = try await daemon.start(waitingFor: signal)
      Issue.record("expected a failure")
    } catch let error as DaemonError {
      guard case .exitedBeforeReady(let code, let output) = error else {
        Issue.record("expected exitedBeforeReady, got \(error)")
        return
      }
      #expect(code == 1)
      // The actual cause, not a status code.
      #expect(output.contains("ERR_NGROK_108"))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  /// A daemon that starts but never announces itself must not hang the server forever.
  @Test("A daemon that never signals readiness times out")
  func readinessTimeout() async {
    let daemon = DaemonProcess(configuration: shellDaemon(script: "sleep 20"))
    let signal = ReadinessSignal(timeout: .milliseconds(300)) { _ in nil }

    do {
      _ = try await daemon.start(waitingFor: signal)
      Issue.record("expected a timeout")
    } catch let error as DaemonError {
      guard case .readyTimeout = error else {
        Issue.record("expected readyTimeout, got \(error)")
        return
      }
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    await daemon.stop()
  }

  @Test("A missing executable is reported by path")
  func missingExecutable() async {
    let daemon = DaemonProcess(
      configuration: DaemonConfiguration(
        name: "absent", executablePath: "/nope/not-a-binary"
      )
    )
    await #expect(throws: DaemonError.executableMissing(path: "/nope/not-a-binary")) {
      _ = try await daemon.start()
    }
  }

  @Test("Stopping terminates the process")
  func stopTerminates() async throws {
    let daemon = DaemonProcess(configuration: shellDaemon(script: "sleep 20"))
    _ = try await daemon.start()
    #expect(await daemon.isRunning)

    await daemon.stop()
    #expect(await !daemon.isRunning)
  }

  /// Both streams are merged because these binaries print their URL to one and their errors
  /// to the other, and which is which differs between them and between versions.
  @Test("Output is captured from both stdout and stderr")
  func capturesBothStreams() async throws {
    let daemon = DaemonProcess(
      configuration: shellDaemon(script: "echo out; echo err >&2; sleep 5")
    )
    _ = try await daemon.start()

    var output: [String] = []
    for _ in 0..<50 {
      output = await daemon.recentOutput
      if output.count >= 2 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(output.contains("out"))
    #expect(output.contains("err"))
    await daemon.stop()
  }

  /// A crash long after the last one is a fresh problem; a burst means the daemon cannot
  /// run here and retrying forever is noise.
  @Test("The restart window resets the failure count")
  func restartWindow() async {
    let daemon = DaemonProcess(
      configuration: DaemonConfiguration(
        name: "x", executablePath: "/bin/sh",
        maximumRestarts: 3, restartWindow: .seconds(60)
      )
    )
    let start = ContinuousClock.now
    #expect(await daemon.shouldRestart(now: start))
    #expect(await daemon.shouldRestart(now: start.advanced(by: .seconds(1))))
    #expect(await daemon.shouldRestart(now: start.advanced(by: .seconds(2))))
    // Fourth inside the window: give up.
    #expect(await !daemon.shouldRestart(now: start.advanced(by: .seconds(3))))

    // Well outside the window: a fresh problem, so a fresh count.
    #expect(await daemon.shouldRestart(now: start.advanced(by: .seconds(120))))
  }
}

@Suite("Tunnel URL extraction")
struct TunnelParsingTests {

  /// ngrok's own API URL also appears in its log, so matching bare "https" yields a tunnel
  /// to nowhere. The `url=` key is what distinguishes them.
  @Test("ngrok's logfmt URL is matched by key, not by scheme")
  func ngrokParsing() {
    let tunnel = Tunnels.ngrok(
      executablePath: "/bin/sh", port: 1234
    )
    _ = tunnel  // constructed to prove the arguments compose

    // The extraction itself, exercised through a daemon that prints ngrok-shaped output.
    let line =
      "t=2026-01-01T00:00:00+0000 lvl=info msg=\"started tunnel\" url=https://abcd.ngrok-free.app"
    guard let range = line.range(of: "url=https://") else {
      Issue.record("expected to find the url key")
      return
    }
    let tail = line[range.lowerBound...].dropFirst("url=".count)
    #expect(String(tail.prefix { !$0.isWhitespace }) == "https://abcd.ngrok-free.app")
  }

  /// The three tunnels differ only in configuration, which is the point of unifying them.
  @Test("Each tunnel declares whether it needs periodic refreshing")
  func refreshRequirements() {
    // ngrok's free tier expires sessions; the others do not.
    #expect(Tunnels.ngrok(executablePath: "/bin/sh", port: 1).requiresRefresh)
    #expect(
      !Tunnels.cloudflare(
        executablePath: "/bin/sh", port: 1,
        options: CloudflareOptions(configFile: "/dev/null")
      ).requiresRefresh)
    #expect(!Tunnels.zrok(executablePath: "/bin/sh", port: 1).requiresRefresh)
  }
}

@Suite("Cloudflare arguments")
struct CloudflareArgumentTests {

  /// The regression that motivated all of this: cloudflared reads `~/.cloudflared/config.yml`
  /// unless told otherwise, and Cloudflare documents quick tunnels as unsupported when it
  /// finds one. A user running cloudflared for something else had this server's DEFAULT
  /// connection method fail with nothing on screen to explain it.
  @Test("A configuration file is always specified")
  func configAlwaysPassed() {
    let arguments = CloudflareOptions(configFile: "/tmp/bb/config.yml")
      .arguments(forwardingTo: 1234)

    guard let index = arguments.firstIndex(of: "--config") else {
      Issue.record("cloudflared was left to find its own configuration")
      return
    }
    #expect(arguments[index + 1] == "/tmp/bb/config.yml")
  }

  /// Anything the user left alone must not appear at all. A flag beats a config file, so
  /// restating cloudflared's own default as a flag would silently overrule whatever the user
  /// had set in a configuration file they imported.
  @Test("Defaults are omitted rather than restated")
  func defaultsAreOmitted() {
    let arguments = CloudflareOptions(configFile: "/tmp/config.yml")
      .arguments(forwardingTo: 1234)

    #expect(!arguments.contains("--protocol"))
    #expect(!arguments.contains("--edge-ip-version"))
    #expect(!arguments.contains("--region"))
    #expect(!arguments.contains("--loglevel"))
  }

  @Test("An explicit choice is passed through")
  func explicitChoicesArePassed() {
    let arguments = CloudflareOptions(
      configFile: "/tmp/config.yml",
      transportProtocol: "http2",
      edgeIPVersion: "6",
      region: "us",
      verboseLogging: true
    ).arguments(forwardingTo: 1234)

    #expect(arguments.contains("--protocol"))
    #expect(arguments.contains("http2"))
    #expect(arguments.contains("--edge-ip-version"))
    #expect(arguments.contains("6"))
    #expect(arguments.contains("--region"))
    #expect(arguments.contains("us"))
    #expect(arguments.contains("--loglevel"))
    #expect(arguments.contains("debug"))
  }

  /// "Serve over HTTPS" makes the local server speak TLS. The origin URL was hardcoded to
  /// http, so turning that setting on left cloudflared retrying against a port that would
  /// never answer it in plaintext.
  @Test("The origin scheme follows this server's own TLS setting")
  func originSchemeFollowsTLS() {
    let plain = CloudflareOptions(configFile: "/tmp/config.yml")
      .arguments(forwardingTo: 1234)
    #expect(plain.contains("http://localhost:1234"))
    #expect(!plain.contains("--no-tls-verify"))

    let secured = CloudflareOptions(configFile: "/tmp/config.yml", originUsesTLS: true)
      .arguments(forwardingTo: 1234)
    #expect(secured.contains("https://localhost:1234"))
    // The certificate on loopback is self-signed or privately imported; verifying it would
    // be checking this Mac against itself.
    #expect(secured.contains("--no-tls-verify"))
  }

  /// The one that matters most. A process's arguments are world-readable on macOS, so a
  /// token on the command line hands control of the user's tunnel to every account on the
  /// machine. It travels in the environment, which reading requires root.
  @Test("The tunnel token never appears on the command line")
  func tokenIsNotAnArgument() {
    let secret = "eyJhIjoiSECRETVALUE"
    let options = CloudflareOptions(
      configFile: "/tmp/config.yml",
      mode: .token,
      token: secret,
      hostname: "messages.example.com"
    )

    let arguments = options.arguments(forwardingTo: 1234)
    #expect(!arguments.contains("--token"))
    for argument in arguments {
      #expect(!argument.contains(secret))
    }
    // It has to reach cloudflared somehow, and this is the documented way.
    #expect(options.environment["TUNNEL_TOKEN"] == secret)
  }

  /// Nothing is put in the environment for the modes that have no token, so a stale value
  /// cannot leak into a quick tunnel after someone switches back.
  @Test("Only a token tunnel carries a token in its environment")
  func environmentIsEmptyWithoutAToken() {
    #expect(CloudflareOptions(configFile: "/c.yml").environment.isEmpty)
    #expect(
      CloudflareOptions(configFile: "/c.yml", mode: .configuration, token: "leftover")
        .environment.isEmpty)
    #expect(
      CloudflareOptions(configFile: "/c.yml", mode: .token, token: "")
        .environment.isEmpty)
  }

  /// cloudflared declares the token and credentials flags on `tunnel run`, and a quick
  /// tunnel takes no subcommand at all. A flag on the wrong side of the subcommand is a
  /// usage error, not something it quietly tolerates.
  @Test("Named tunnels use the run subcommand and quick tunnels do not")
  func subcommandPlacement() {
    let quick = CloudflareOptions(configFile: "/c.yml").arguments(forwardingTo: 80)
    #expect(!quick.contains("run"))

    for mode in [CloudflareOptions.Mode.token, .configuration] {
      let arguments = CloudflareOptions(
        configFile: "/c.yml", mode: mode, token: "t", hostname: "h.example.com"
      ).arguments(forwardingTo: 80)

      guard let run = arguments.firstIndex(of: "run") else {
        Issue.record("\(mode) should run a named tunnel")
        return
      }
      // Global flags before the subcommand, origin flags after it.
      guard let config = arguments.firstIndex(of: "--config"),
        let url = arguments.firstIndex(of: "--url")
      else {
        Issue.record("expected both --config and --url")
        return
      }
      #expect(config < run)
      #expect(url > run)
    }
  }

  /// A quick tunnel's address is scraped, so there is nothing to announce in advance.
  @Test("A quick tunnel announces no address of its own")
  func quickTunnelHasNoAnnouncedAddress() {
    #expect(CloudflareOptions(configFile: "/tmp/config.yml").publishedAddress == nil)
    // Not even if a hostname is left over from a mode the user has since switched away
    // from — a quick tunnel's address is whatever cloudflared invents, and publishing a
    // stale hostname would point every client somewhere that is not serving them.
    #expect(
      CloudflareOptions(configFile: "/c.yml", hostname: "stale.example.com")
        .publishedAddress == nil)
    #expect(
      CloudflareOptions(configFile: "/c.yml", mode: .token, hostname: "   ")
        .publishedAddress == nil)
  }

  /// A tunnel the user configured themselves never prints its hostname, so the one they
  /// typed IS the address — normalised the way `DynamicDNSProxy` normalises its own.
  @Test("A user's own hostname is published as https")
  func hostnameIsNormalised() {
    #expect(
      CloudflareOptions(
        configFile: "/c.yml", mode: .token, hostname: "messages.example.com"
      ).publishedAddress == "https://messages.example.com")
    // A scheme the user typed is left alone rather than doubled.
    #expect(
      CloudflareOptions(
        configFile: "/c.yml", mode: .configuration, hostname: "http://inside.lan"
      ).publishedAddress == "http://inside.lan")
  }
}

/// Config-file mode hands the tunnel's settings to the user's own `config.yml`.
///
/// The UI greys those fields out; this is the half that makes the greying true. A flag beats
/// a config file, so continuing to pass them would leave the controls looking locked while
/// still overriding the file they say is in charge.
@Suite("Cloudflare config-file mode")
struct CloudflareConfigModeTests {

  private func arguments(mode: CloudflareOptions.Mode) -> [String] {
    CloudflareOptions(
      configFile: "/tmp/config.yml",
      mode: mode,
      hostname: mode == .quick ? "" : "messages.example.com",
      transportProtocol: "http2",
      edgeIPVersion: "6",
      region: "us",
      verboseLogging: true
    ).arguments(forwardingTo: 1234)
  }

  @Test("Tunnel settings are not passed when a config file owns them")
  func tunnelSettingsAreOmittedInConfigMode() {
    let arguments = arguments(mode: .configuration)

    #expect(!arguments.contains("--protocol"))
    #expect(!arguments.contains("--edge-ip-version"))
    #expect(!arguments.contains("--region"))
  }

  @Test("The same settings are passed in the other modes")
  func tunnelSettingsArePassedOtherwise() {
    // The omission has to be specific to config mode, or this is just a regression in
    // the advanced settings.
    for mode in [CloudflareOptions.Mode.quick, .token] {
      let arguments = arguments(mode: mode)
      #expect(arguments.contains("--protocol"), "\(mode) should pass --protocol")
      #expect(arguments.contains("--edge-ip-version"), "\(mode) should pass --edge-ip-version")
      #expect(arguments.contains("--region"), "\(mode) should pass --region")
    }
  }

  @Test("Verbose logging still works in config-file mode")
  func verboseLoggingSurvivesConfigMode() {
    // Deliberately exempt. Verbose logging is not tunnel configuration — it is how
    // somebody diagnoses a tunnel that will not start, which is exactly when a
    // config-file user needs it and the worst moment to make them edit YAML and restart.
    #expect(arguments(mode: .configuration).contains("--loglevel"))
  }

  @Test("The config file itself is still passed")
  func configFileIsStillPassed() {
    let arguments = arguments(mode: .configuration)
    #expect(arguments.contains("--config"))
    #expect(arguments.contains("/tmp/config.yml"))
  }
}

@Suite("ngrok arguments")
struct NgrokArgumentTests {

  /// The one that matters most, and it was wrong. A process's arguments are world-readable
  /// on macOS, so `--authtoken <secret>` handed control of the user's ngrok account to every
  /// other account on the machine. `NGROK_AUTHTOKEN` is ngrok's own variable for this, and
  /// reading another user's environment requires root.
  @Test("The authtoken never appears on the command line")
  func authTokenIsNotAnArgument() {
    let secret = "2abcSECRETTOKENvalue"
    let options = NgrokOptions(authToken: secret)

    let arguments = options.arguments(forwardingTo: 1234)
    #expect(!arguments.contains("--authtoken"))
    for argument in arguments {
      #expect(!argument.contains(secret))
    }
    #expect(options.environment["NGROK_AUTHTOKEN"] == secret)
  }

  /// Nothing in the environment without one, so a blank field cannot set an empty variable
  /// that ngrok would then prefer over its own configuration file.
  @Test("An empty token puts nothing in the environment")
  func emptyTokenIsNotExported() {
    #expect(NgrokOptions().environment.isEmpty)
    #expect(NgrokOptions(authToken: "   ").environment.isEmpty)
  }

  /// Anything left alone must not appear. A flag beats `ngrok.yml`, so restating ngrok's own
  /// default as a flag would silently overrule whatever the user had configured there.
  @Test("Defaults are omitted rather than restated")
  func defaultsAreOmitted() {
    let arguments = NgrokOptions(authToken: "t").arguments(forwardingTo: 1234)

    #expect(!arguments.contains("--region"))
    #expect(!arguments.contains("--domain"))
    #expect(!arguments.contains("--host-header"))
    #expect(!arguments.contains("--inspect=false"))
    #expect(!arguments.contains("--traffic-policy-file"))
    #expect(!arguments.contains("--log-level"))
  }

  @Test("An explicit choice is passed through")
  func explicitChoicesArePassed() {
    let arguments = NgrokOptions(
      authToken: "t",
      region: "eu",
      domain: "messages.example.com",
      hostHeader: "rewrite",
      disableInspection: true,
      trafficPolicyFile: "/tmp/policy.yml",
      verboseLogging: true
    ).arguments(forwardingTo: 1234)

    #expect(arguments.contains("--region"))
    #expect(arguments.contains("eu"))
    #expect(arguments.contains("--domain"))
    #expect(arguments.contains("messages.example.com"))
    #expect(arguments.contains("--host-header"))
    #expect(arguments.contains("rewrite"))
    // One token, not two: `--inspect false` would be parsed as a flag plus a positional.
    #expect(arguments.contains("--inspect=false"))
    #expect(arguments.contains("--traffic-policy-file"))
    #expect(arguments.contains("/tmp/policy.yml"))
    #expect(arguments.contains("--log-level"))
    #expect(arguments.contains("debug"))
  }

  /// Only HTTP endpoints, and that is a decision rather than an omission: the Electron
  /// server offered TCP and then forced the setting back to `http` on every launch, because
  /// a bare host and port is not something a BlueBubbles client can connect to.
  @Test("Only an HTTP endpoint is ever requested")
  func onlyHTTPEndpoints() {
    #expect(NgrokOptions(authToken: "t").arguments(forwardingTo: 1234).first == "http")
  }

  /// The same bug Cloudflare had. "Serve over HTTPS" makes the local server speak TLS, and a
  /// bare port means plaintext — so turning that on left ngrok forwarding into a socket that
  /// would never answer it.
  @Test("The origin scheme follows this server's own TLS setting")
  func originSchemeFollowsTLS() {
    #expect(
      NgrokOptions(authToken: "t").arguments(forwardingTo: 1234)
        .contains("http://localhost:1234"))
    #expect(
      NgrokOptions(authToken: "t", originUsesTLS: true).arguments(forwardingTo: 1234)
        .contains("https://localhost:1234"))
  }
}

@Suite("zrok arguments")
struct ZrokArgumentTests {

  /// Without a reserved token zrok makes a throwaway share, which is what an install that
  /// has never reserved anything should get.
  @Test("An unreserved share is public and proxied")
  func publicShare() {
    let arguments = ZrokOptions().arguments(forwardingTo: 1234)
    #expect(arguments.starts(with: ["share", "public", "http://localhost:1234"]))
    #expect(arguments.contains("--backend-mode"))
    #expect(arguments.contains("proxy"))
    #expect(arguments.contains("--headless"))
    #expect(!arguments.contains("--insecure"))
  }

  /// A reserved share already knows its backend mode from when it was reserved;
  /// `--override-endpoint` is what lets this server's port change without re-reserving.
  @Test("A reserved share is addressed by its token")
  func reservedShare() {
    let arguments = ZrokOptions(reservedToken: "myserver").arguments(forwardingTo: 1234)
    #expect(arguments.starts(with: ["share", "reserved", "myserver"]))
    #expect(arguments.contains("--override-endpoint"))
    #expect(arguments.contains("http://localhost:1234"))
    #expect(!arguments.contains("--backend-mode"))
  }

  /// The third time this file makes the same point: the origin scheme follows the server,
  /// and a certificate on loopback chains to nothing the agent trusts.
  @Test("The origin scheme follows this server's own TLS setting")
  func originSchemeFollowsTLS() {
    let secured = ZrokOptions(originUsesTLS: true).arguments(forwardingTo: 8443)
    #expect(secured.contains("https://localhost:8443"))
    #expect(secured.contains("--insecure"))
  }

  /// Only a self-hosted controller puts anything in the environment, so a blank field cannot
  /// point the agent at nowhere.
  @Test("A self-hosted controller travels in the environment")
  func apiEndpointIsExported() {
    #expect(ZrokOptions().environment.isEmpty)
    #expect(ZrokOptions(apiEndpoint: "  ").environment.isEmpty)
    #expect(
      ZrokOptions(apiEndpoint: "https://zrok.example.com").environment["ZROK_API_ENDPOINT"]
        == "https://zrok.example.com")
  }

  @Test("Verbose logging is opt-in")
  func verboseIsOptIn() {
    #expect(!ZrokOptions().arguments(forwardingTo: 1).contains("-v"))
    #expect(ZrokOptions(verboseLogging: true).arguments(forwardingTo: 1).contains("-v"))
  }
}

@Suite("zrok setup output")
struct ZrokEnvironmentParsingTests {

  /// `zrok reserve` prints the token inside a sentence, alongside a URL that also contains a
  /// token-shaped word — which is why this matches the sentence rather than the shape.
  @Test("The reserved share token is read out of zrok's own sentence")
  func reservedTokenIsParsed() {
    let output = """
      [   0.412]    INFO main.(*reservePublic).run: your reserved share token is 'q1w2e3r4'
      [   0.413]    INFO main.(*reservePublic).run: reserved frontend endpoint: https://q1w2e3r4.share.zrok.io
      """
    #expect(ZrokEnvironment.reservedToken(in: output) == "q1w2e3r4")
  }

  /// A reserve that succeeded but printed something unfamiliar is reported rather than
  /// guessed at: adopting the wrong token means sharing to an address nobody is watching.
  @Test("Unrecognised output yields no token")
  func unparseableOutputYieldsNil() {
    #expect(ZrokEnvironment.reservedToken(in: "") == nil)
    #expect(ZrokEnvironment.reservedToken(in: "something else entirely") == nil)
    // An unterminated quote is not a token.
    #expect(ZrokEnvironment.reservedToken(in: "reserved share token is 'abc") == nil)
  }

  /// The four conditions the TypeScript server checked before adopting a share, kept in one
  /// place so "is this ours" cannot be answered differently in two callers.
  @Test("A share is only adopted when it matches this server exactly")
  func shareMatching() {
    func share(
      mode: String = "public",
      backend: String = "proxy",
      endpoint: String = "http://localhost:1234",
      reserved: Bool = true
    ) -> ZrokShare {
      ZrokShare(
        token: "t", shareMode: mode, backendMode: backend,
        backendProxyEndpoint: endpoint, isReserved: reserved, frontendEndpoint: nil
      )
    }
    let endpoint = "http://localhost:1234"

    #expect(share().matches(endpoint: endpoint, backendMode: "proxy"))
    // A share left over from a different port must not be adopted — it would forward to
    // something that is no longer this server.
    #expect(
      !share(endpoint: "http://localhost:9999").matches(endpoint: endpoint, backendMode: "proxy"))
    #expect(!share(reserved: false).matches(endpoint: endpoint, backendMode: "proxy"))
    #expect(!share(mode: "private").matches(endpoint: endpoint, backendMode: "proxy"))
    #expect(!share(backend: "web").matches(endpoint: endpoint, backendMode: "proxy"))
  }
}

@Suite("A tunnel that dies comes back", .serialized)
struct TunnelReconnectionTests {

  /// `DaemonProcess` carried a restart budget and a `shouldRestart()` to spend it from the
  /// day it was written, and nothing in production ever called either: `onExit` was left at
  /// its default no-op. A tunnel that died stayed dead, the server went on publishing an
  /// address that resolved to nothing, and the only way back was relaunching the app.
  ///
  /// A quick tunnel comes back with a DIFFERENT address, which is why simply restarting is
  /// not enough — the new one has to reach whoever publishes it.
  @Test("A new address is republished after an unexpected exit")
  func republishesAfterExit() async throws {
    // Prints one URL, exits; prints a different URL on the next run, and stays.
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-reconnect-\(UUID().uuidString)").path
    let script = """
      if [ -f \(marker) ]; then
        echo 'url=https://second.example.com'; sleep 20
      else
        touch \(marker); echo 'url=https://first.example.com'; exit 3
      fi
      """
    defer { try? FileManager.default.removeItem(atPath: marker) }

    let tunnel = BinaryTunnel(
      identifier: ServiceIdentifier("app.bluebubbles.proxy.cloudflare"),
      requiresRefresh: false,
      configuration: DaemonConfiguration(
        name: "reconnect-test",
        executablePath: "/bin/sh",
        arguments: ["-c", script],
        restartDelay: .milliseconds(50)
      ),
      readiness: ReadinessSignal(timeout: .seconds(10)) { line in
        guard let range = line.range(of: "url=") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      }
    )

    let republished = Republished()
    await tunnel.observe(
      ProxyObserver(addressChanged: { await republished.record($0) })
    )

    let first = try await tunnel.connect()
    #expect(first == "https://first.example.com")

    // The script exits on its own the moment it has printed, so nothing here asks it to.
    try await waitUntil(.seconds(10)) { await republished.latest != nil }

    #expect(await republished.latest == "https://second.example.com")
    #expect(await tunnel.currentAddress == "https://second.example.com")
    await tunnel.disconnect()
  }

  /// Stopping deliberately is not a crash, and must not start a reconnect race against the
  /// shutdown that asked for it.
  @Test("Disconnecting does not trigger a reconnect")
  func deliberateStopIsNotRestarted() async throws {
    let tunnel = BinaryTunnel(
      identifier: ServiceIdentifier("app.bluebubbles.proxy.cloudflare"),
      requiresRefresh: false,
      configuration: DaemonConfiguration(
        name: "stop-test",
        executablePath: "/bin/sh",
        // Deliberately FORKS rather than execs, so `sleep` outlives the shell and goes on
        // holding the output pipe. That is what a tunnel binary with a helper process
        // looks like, and a blocking drain used to wait the full twenty seconds for it.
        arguments: ["-c", "echo 'url=https://only.example.com'; sleep 20"],
        restartDelay: .milliseconds(50)
      ),
      readiness: ReadinessSignal(timeout: .seconds(10)) { line in
        guard let range = line.range(of: "url=") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      }
    )

    let republished = Republished()
    await tunnel.observe(
      ProxyObserver(addressChanged: { await republished.record($0) })
    )

    _ = try await tunnel.connect()
    await tunnel.disconnect()

    // Long enough for a spurious restart to have happened and announced itself.
    try await Task.sleep(for: .milliseconds(400))
    #expect(await republished.latest == nil)
    #expect(await tunnel.currentAddress == nil)
  }
}

/// Collects what a tunnel republished, from whichever task the observer runs on.
private actor Republished {
  private(set) var latest: String?
  func record(_ address: String) { latest = address }
}

/// Polls a condition rather than sleeping a guessed interval, so a slow machine does not turn
/// a passing test into a flaky one.
private func waitUntil(
  _ timeout: Duration,
  _ condition: @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(25))
  }
  Issue.record("condition was still false after \(timeout)")
}

@Suite("Non-tunnelling providers")
struct StaticProviderTests {

  /// A user who typed a bare hostname should still get a usable URL.
  @Test("A dynamic DNS address is normalised to a URL")
  func dynamicDNSNormalisation() async throws {
    #expect(
      try await DynamicDNSProxy(address: "home.example.com").connect()
        == "https://home.example.com")
    // An explicit scheme is respected.
    #expect(
      try await DynamicDNSProxy(address: "http://home.example.com").connect()
        == "http://home.example.com")
    #expect(
      try await DynamicDNSProxy(address: "  home.example.com  ").connect()
        == "https://home.example.com")
  }

  @Test("An empty dynamic DNS address is refused")
  func emptyDynamicDNS() async {
    await #expect(throws: ProxyError.self) {
      _ = try await DynamicDNSProxy(address: "   ").connect()
    }
  }

  @Test("The LAN provider builds a URL from the resolved address")
  func lanAddress() async throws {
    let proxy = LANProxy(port: 1234, useTLS: false) { "192.168.1.42" }
    #expect(try await proxy.connect() == "http://192.168.1.42:1234")

    let secure = LANProxy(port: 443, useTLS: true) { "192.168.1.42" }
    #expect(try await secure.connect() == "https://192.168.1.42:443")
  }

  @Test("An unresolvable LAN address is reported rather than guessed")
  func lanUnavailable() async {
    let proxy = LANProxy(port: 1234) { nil }
    await #expect(throws: ProxyError.addressUnavailable) { _ = try await proxy.connect() }
  }

  /// Reads the machine's real interfaces, so this asserts shape rather than a value.
  @Test("Interface enumeration returns plausible IPv4 addresses")
  func interfaceEnumeration() {
    for address in SystemInfo.localAddresses(.ipv4) {
      let octets = address.split(separator: ".")
      #expect(octets.count == 4, "\(address) is not a dotted quad")
      #expect(!address.hasPrefix("127."), "loopback should be excluded")
    }
  }
}

@Suite("Refresh policy")
struct RefreshPolicyTests {

  /// Restarting mid-download truncates an attachment transfer, which is why the tunnel
  /// waits for the server to be idle before recycling its session.
  @Test("A recent connection means the server is not idle")
  func idleDetection() {
    let policy = RefreshPolicy(idleThreshold: .seconds(120))
    let now = Date()

    #expect(!policy.isIdle(lastConnectionAt: now, now: now))
    #expect(!policy.isIdle(lastConnectionAt: now.addingTimeInterval(-60), now: now))
    #expect(policy.isIdle(lastConnectionAt: now.addingTimeInterval(-300), now: now))
    // Never connected.
    #expect(policy.isIdle(lastConnectionAt: nil, now: now))
  }

  /// Seven hours, comfortably inside ngrok's free-tier session limit.
  @Test("The default refresh interval stays under the session limit")
  func defaultInterval() {
    #expect(RefreshPolicy.default.interval == .seconds(7 * 60 * 60))
    // And it gives up waiting for idle rather than holding a dead tunnel forever.
    #expect(RefreshPolicy.default.maximumWait == .seconds(600))
  }
}
