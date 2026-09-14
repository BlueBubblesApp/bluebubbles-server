//  TunnelCommandLineTests
//  What this server actually asks cloudflared, ngrok and zrok to do.
//
//  `BBProxy` had no test target at all, which for this module is worse than it sounds. Every
//  interesting decision in it is a command line or an environment for a program that is not
//  installed on a CI runner, so "it built" is the entire assurance the module had, and
//  nothing in a command line fails to compile: a flag on the wrong side of a subcommand, a
//  v2 spelling the installed agent rejects outright, a credential moved from the environment
//  onto a world-readable argument list are all valid Swift.
//
//  They are also invisible in use. A tunnel that will not start reads to the user as the
//  connection method being broken, and the flag that did it is inside a daemon's own stderr.
//
//  Three of the options types split their argument building out of the actor that spawns
//  them precisely so it could be checked without spawning anything, and their headers say so.
//  This is the check those headers were written for.

import Foundation
import Testing

@testable import BBProxy

@Suite("Tunnel command lines")
struct TunnelCommandLineTests {

  // MARK: - cloudflared

  @Test("A quick tunnel takes no `run` subcommand and the other two modes do")
  func cloudflareSubcommandPlacement() {
    let quick = CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .quick).arguments(
      forwardingTo: 1234)
    #expect(!quick.contains("run"), "cloudflared rejects `--url` after `run` on a quick tunnel")
    #expect(quick.starts(with: ["tunnel"]))

    for mode in [CloudflareOptions.Mode.token, .configuration] {
      let arguments = CloudflareOptions(
        configFile: "/tmp/bb/config.yml", mode: mode, token: "t", hostname: "h.example.com"
      )
      .arguments(forwardingTo: 1234)
      let run = arguments.firstIndex(of: "run")
      let url = arguments.firstIndex(of: "--url")
      #expect(run != nil, "\(mode) must name the `run` subcommand")
      #expect(
        run != nil && url != nil && run! < url!,
        "`--url` is declared on `tunnel run`, so it goes after the subcommand")
      #expect(
        arguments.firstIndex(of: "--config").map { $0 < run! } == true,
        "`--config` is a global flag and a usage error after the subcommand")
    }
  }

  @Test("A cloudflared default is never spelled out on the command line")
  func cloudflareOmitsItsOwnDefaults() {
    let arguments = CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .quick).arguments(
      forwardingTo: 1234)
    #expect(!arguments.contains("--protocol"))
    #expect(!arguments.contains("--edge-ip-version"))
    // Older cloudflared builds reject `--region global` outright.
    #expect(!arguments.contains("--region"))
  }

  @Test("Config-file mode emits no tunnel flags, but still emits the log level")
  func cloudflareConfigurationModeDefersToTheFile() {
    let options = CloudflareOptions(
      configFile: "/tmp/bb/config.yml", mode: .configuration, transportProtocol: "http2",
      edgeIPVersion: "6", region: "us",
      verboseLogging: true)
    let arguments = options.arguments(forwardingTo: 1234)
    for flag in ["--protocol", "--edge-ip-version", "--region"] {
      #expect(
        !arguments.contains(flag),
        "\(flag) would beat the file the user said IS the configuration")
    }
    #expect(
      arguments.contains("--loglevel"),
      "verbose logging is how a config-file user diagnoses a tunnel that will not start")
  }

  @Test("The cloudflared token is on the environment and never on the argument list")
  func cloudflareTokenNeverReachesTheArgumentList() {
    let secret = "eyJhIjoiTEVBS0VEIn0="
    let options = CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .token, token: secret)
    #expect(options.environment["TUNNEL_TOKEN"] == secret)
    let arguments = options.arguments(forwardingTo: 1234)
    #expect(
      !arguments.contains { $0.contains(secret) },
      "a process's arguments are world-readable; its environment is not")
    #expect(!arguments.contains("--token"))
    // A mode that carries no token carries no variable either, rather than an empty one.
    #expect(
      CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .quick, token: secret).environment
        .isEmpty)
    #expect(
      CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .token, token: "").environment
        .isEmpty)
  }

  @Test("The origin scheme follows this server, and TLS turns verification off")
  func cloudflareOriginFollowsTheServer() {
    let plain = CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .quick).arguments(
      forwardingTo: 5678)
    #expect(plain.contains("http://localhost:5678"))
    #expect(!plain.contains("--no-tls-verify"))

    let secure = CloudflareOptions(
      configFile: "/tmp/bb/config.yml", mode: .quick, originUsesTLS: true
    ).arguments(forwardingTo: 5678)
    #expect(secure.contains("https://localhost:5678"))
    #expect(
      secure.contains("--no-tls-verify"),
      "loopback's certificate chains to nothing cloudflared trusts")
  }

  @Test("Only a named mode publishes an address, and it is given a scheme")
  func cloudflarePublishedAddress() {
    #expect(
      CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .quick, hostname: "h.example.com")
        .publishedAddress == nil)
    #expect(
      CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .token, hostname: "h.example.com")
        .publishedAddress
        == "https://h.example.com")
    #expect(
      CloudflareOptions(
        configFile: "/tmp/bb/config.yml", mode: .token, hostname: "http://h.example.com"
      ).publishedAddress
        == "http://h.example.com", "a scheme the user typed is left alone")
    #expect(
      CloudflareOptions(configFile: "/tmp/bb/config.yml", mode: .token, hostname: "  ")
        .publishedAddress == nil)
  }

  // MARK: - ngrok

  @Test("ngrok is driven with v3 spellings only")
  func ngrokUsesVersionThreeFlags() {
    let arguments = NgrokOptions(domain: "example.ngrok.app").arguments(forwardingTo: 1234)
    #expect(arguments.contains("--domain"))
    for rejected in ["--hostname", "--subdomain"] {
      #expect(
        !arguments.contains(rejected),
        "the v3 agent this server installs rejects \(rejected) outright")
    }
  }

  @Test("ngrok's URL is scraped from stdout, so the log flags are unconditional")
  func ngrokAlwaysLogsToStdout() {
    let arguments = NgrokOptions().arguments(forwardingTo: 1234)
    #expect(arguments.contains("--log"))
    #expect(arguments.contains("stdout"))
    #expect(arguments.contains("--log-format"))
    #expect(arguments.contains("logfmt"))
    #expect(arguments.first == "http")
    #expect(arguments.contains("http://localhost:1234"))
  }

  @Test("Disabling inspection is one token, because it is a boolean flag")
  func ngrokInspectionFlagIsOneToken() {
    let arguments = NgrokOptions(disableInspection: true).arguments(forwardingTo: 1234)
    #expect(
      arguments.contains("--inspect=false"),
      "`--inspect false` parses as the flag plus a positional argument")
    #expect(!arguments.contains("--inspect"))
    #expect(!NgrokOptions().arguments(forwardingTo: 1234).contains("--inspect=false"))
  }

  @Test("The ngrok auth token is on the environment and never on the argument list")
  func ngrokTokenNeverReachesTheArgumentList() {
    let secret = "2abcLEAKEDdefGHI"
    let options = NgrokOptions(authToken: "  \(secret)  ")
    #expect(options.environment["NGROK_AUTHTOKEN"] == secret, "trimmed, not passed through raw")
    #expect(!options.arguments(forwardingTo: 1234).contains { $0.contains(secret) })
    #expect(NgrokOptions(authToken: "   ").environment.isEmpty)
  }

  @Test("ngrok omits its own default region and follows the server's scheme")
  func ngrokRegionAndScheme() {
    #expect(!NgrokOptions().arguments(forwardingTo: 1).contains("--region"))
    #expect(NgrokOptions(region: "eu").arguments(forwardingTo: 1).contains("eu"))
    #expect(
      NgrokOptions(originUsesTLS: true).arguments(forwardingTo: 99)
        .contains("https://localhost:99"))
  }

  // MARK: - zrok

  @Test("A reserved share and a throwaway share are different commands")
  func zrokShareShape() {
    let throwaway = ZrokOptions().arguments(forwardingTo: 1234)
    #expect(throwaway.starts(with: ["share", "public", "http://localhost:1234"]))
    #expect(throwaway.contains("--backend-mode"))
    #expect(!throwaway.contains("--override-endpoint"))

    let reserved = ZrokOptions(reservedToken: " tok3n ").arguments(forwardingTo: 1234)
    #expect(reserved.starts(with: ["share", "reserved", "tok3n"]), "the token is trimmed")
    #expect(
      reserved.contains("--override-endpoint"),
      "without it the share cannot follow a port change without being re-reserved")
    #expect(
      !reserved.contains("--backend-mode"),
      "a reserved share already knows its backend mode from when it was reserved")
    #expect(ZrokOptions(reservedToken: " tok3n ").isReserved)
    #expect(!ZrokOptions(reservedToken: "  ").isReserved)
  }

  @Test("zrok is headless, and skips verification only when the origin speaks TLS")
  func zrokHeadlessAndInsecure() {
    #expect(ZrokOptions().arguments(forwardingTo: 1).contains("--headless"))
    #expect(!ZrokOptions().arguments(forwardingTo: 1).contains("--insecure"))
    let secure = ZrokOptions(originUsesTLS: true).arguments(forwardingTo: 1)
    #expect(secure.contains("--insecure"))
    #expect(secure.contains("https://localhost:1"))
  }

  /// REGRESSION. The line zrok actually emits, which is JSON.
  ///
  /// The reader took everything up to the next whitespace, and compact JSON has none after
  /// the value, so the published address carried the rest of the object with it:
  /// `https://…share.zrok.io","time":"…"}`. It reached `server_address`, Firebase and every
  /// client, so the tunnel was up and unreachable.
  @Test("The share address is read out of zrok's JSON, not to the end of the line")
  func zrokShareAddressFromJSON() {
    let line =
      #"{"level":"info","msg":"access your share","url":"https://sq292s89ck5g.share.zrok.io","time":"2026-09-14T15:38:33.797Z"}"#
    #expect(Tunnels.shareAddress(in: line) == "https://sq292s89ck5g.share.zrok.io")
  }

  /// The URL as the last value in the object, where the closing brace follows the quote.
  @Test("A share address at the end of the object drops the brace")
  func zrokShareAddressAtTheEnd() {
    let line = #"{"msg":"zrok share","url":"https://abc123.share.zrok.io"}"#
    #expect(Tunnels.shareAddress(in: line) == "https://abc123.share.zrok.io")
  }

  /// A self-hosted controller hands out its own domain, so the host is not checked against
  /// zrok's. Demanding `share.zrok.io` would break exactly the people running their own.
  @Test("A self-hosted controller's own domain is accepted")
  func zrokSelfHostedDomain() {
    let line = #"{"msg":"zrok share started","url":"https://share.example.com"}"#
    #expect(Tunnels.shareAddress(in: line) == "https://share.example.com")
  }

  /// Plain console output, which is what it used to be read from.
  @Test("A bare line still reads, with the whitespace and quotes trimmed")
  func zrokShareAddressPlainLine() {
    #expect(
      Tunnels.shareAddress(in: "zrok: https://xyz.share.zrok.io  ")
        == "https://xyz.share.zrok.io")
  }

  @Test("Lines that carry no usable zrok address are refused")
  func zrokShareAddressRejects() {
    for line in [
      // No URL at all.
      #"{"level":"info","msg":"zrok starting","time":"2026-09-14T15:38:33.797Z"}"#,
      // Not zrok's output: another tunnel's line must not be taken for one.
      "https://red-fox-1234.trycloudflare.com",
      // A scheme with nothing behind it.
      #"{"msg":"zrok","url":"https://"}"#,
    ] {
      #expect(Tunnels.shareAddress(in: line) == nil, "accepted \(line)")
    }
  }

  @Test("A self-hosted zrok controller is named on the environment, shared by every call")
  func zrokApiEndpoint() {
    #expect(ZrokOptions().environment.isEmpty)
    #expect(
      ZrokOptions(apiEndpoint: " https://zrok.example.com ").environment["ZROK_API_ENDPOINT"]
        == "https://zrok.example.com")
  }

  // MARK: - Reading an assigned address back

  @Test("A quick tunnel address is recognised inside cloudflared's ASCII box")
  func quickTunnelAddressIsFoundInTheBanner() {
    let line = "|  https://red-fox-1234.trycloudflare.com                       |"
    #expect(Tunnels.quickTunnelAddress(in: line) == "https://red-fox-1234.trycloudflare.com")
    #expect(
      Tunnels.quickTunnelAddress(in: "INF |  https://a-b.trycloudflare.com |")
        == "https://a-b.trycloudflare.com")
  }

  @Test("Everything else cloudflared prints with an https:// in it is refused")
  func quickTunnelAddressRejectsTheLookalikes() {
    let refused = [
      // The API endpoint cloudflared reports errors against: not a subdomain of the
      // tunnel domain, and it has a path.
      "ERR failed to request quick tunnel: https://api.trycloudflare.com/tunnel",
      // A JSON error body, whose trailing quote makes the token unparseable.
      #"{"error":"https://api.trycloudflare.com/tunnel":"#,
      // Some other Cloudflare URL entirely.
      "INF Visit https://developers.cloudflare.com/argo-tunnel",
      "INF Registered tunnel connection",
      "",
    ]
    for line in refused {
      #expect(
        Tunnels.quickTunnelAddress(in: line) == nil,
        Comment(rawValue: "accepted a line it should have ignored: \(line)"))
    }
  }
}
