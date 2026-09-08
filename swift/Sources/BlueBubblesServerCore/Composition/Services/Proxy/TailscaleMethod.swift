//  TailscaleMethod
//  Tailscale, driven through the managed `tailscaled` and `tailscale` binaries.

import BBBuiltIns
import BBDiagnostics
import BBPrivateAPIContract
import BBProxy
import BBServiceKit
import BBSettings
import Foundation

/// Tailscale: the connection method whose setup can wait on a person.
///
/// The provider does the waiting — see `TailscaleTunnel` — and this is where what it is
/// waiting FOR is turned into a notification with the link to act on. Three of the four
/// steps carry a URL Tailscale printed or documents; the fourth, device approval, has a
/// page in the admin console that never moves.
enum TailscaleMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.tailscale }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let daemonPath = await host.toolExecutable() else { return nil }

    // The CLI is the second half of every Tailscale distribution and sits beside the
    // daemon in all of them — Homebrew's bottle, a source build, the standalone tarballs
    // on other platforms. A daemon without it cannot be signed in or told what to serve,
    // and that is reported rather than guessed at.
    guard let cliPath = commandLineTool(beside: daemonPath) else {
      await host.complain(
        title: "Tailscale is missing its command-line tool",
        body: "The `tailscale` program should be next to `tailscaled` at \(daemonPath), "
          + "and is not. Reinstall Tailscale from the Tailscale page, or point this server "
          + "at an install that has both.",
        key: "cli-missing"
      )
      return nil
    }

    let exposure =
      TailscaleOptions.Exposure(rawValue: await host.ownOrDefault("exposure", "tailnet"))
      ?? .tailnet
    let httpsPort = Int(await host.ownOrDefault("https_port", "443")) ?? 443

    let stateDirectory = SocketLocation.supportDirectory + "/tailscale"
    do {
      // Readable by this user only: the node key inside it IS this Mac's identity on the
      // tailnet.
      try FileManager.default.createDirectory(
        atPath: stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      await host.complain(
        title: "Tailscale has nowhere to keep its state",
        body: "This server could not create \(stateDirectory), which is where the "
          + "Tailscale daemon keeps this Mac's key and certificates.",
        key: "state-directory"
      )
      return nil
    }

    let options = TailscaleOptions(
      hostname: TailscaleOptions.sanitisedHostname(await host.own("hostname")),
      exposure: exposure,
      httpsPort: httpsPort,
      // Read from the Keychain, because the field is declared `isSecret`. It goes no
      // further than a mode-0600 file the CLI reads and the tunnel deletes.
      authKey: await host.own("auth_key"),
      controlURL: await host.own("control_url"),
      sendLogs: await host.ownFlag("send_logs"),
      verboseLogging: await host.ownFlag("verbose_logging"),
      // Declared on the manifest, so this read is allowed and is on the permissions
      // list. Not a Tailscale option — it is a fact about the origin serve proxies to.
      originUsesTLS: await host.scoped.valueOrDefault(Settings.useCustomCertificate),
      stateDirectory: stateDirectory,
      socketPath: socketPath()
    )

    return Tunnels.tailscale(
      daemonExecutablePath: daemonPath,
      cliExecutablePath: cliPath,
      port: await host.forwardedPort(),
      options: options,
      onAttention: { attention in await report(attention, host: host) }
    )
  }

  /// The `tailscale` CLI that ships with a `tailscaled`.
  static func commandLineTool(beside daemonPath: String) -> String? {
    let candidate = (daemonPath as NSString).deletingLastPathComponent + "/tailscale"
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
  }

  /// Where the daemon's control socket lives.
  ///
  /// The per-user temporary directory rather than Application Support: a Unix socket path
  /// is capped at 104 bytes on macOS, and Application Support plus a long user name does
  /// not fit. The directory is per user and stable across processes, which is all a socket
  /// needs, and the daemon recreates the socket on every start.
  static func socketPath() -> String {
    NSTemporaryDirectory() + "bluebubbles-tailscaled.sock"
  }

  // MARK: - Telling the person

  /// The Tailscale admin pages, for the steps where Tailscale printed no link of its own.
  private enum Pages {
    static let machines = URL(string: "https://login.tailscale.com/admin/machines")
    /// Tailscale's own short links, from the messages its CLI prints for the same two
    /// conditions.
    static let https = URL(string: "https://tailscale.com/s/https")
    static let funnel = URL(string: "https://tailscale.com/s/no-funnel")
  }

  /// Raises the notification for a step only the tailnet's owner can take.
  ///
  /// Keyed by step AND link: a sign-in link belongs to one daemon, and a daemon that came
  /// back after a crash has a different one, which a deduplicated alert would go on
  /// showing the old text for.
  private static func report(_ attention: TailscaleAttention, host: ProxyHost) async {
    let title: String
    let body: String
    let link: URL?
    let key: String

    switch attention {
    case .signInRequired(let url):
      title = "Sign in to Tailscale to finish connecting"
      body =
        "Open the link and sign this Mac in to your Tailscale account. The connection "
        + "starts on its own once you have. To skip this step in future, paste an auth "
        + "key from the Tailscale admin console on the Tailscale page."
      link = url
      key = "sign-in.\(url.lastPathComponent)"

    case .deviceApprovalRequired:
      title = "Approve this Mac in the Tailscale admin console"
      body =
        "Your tailnet approves new devices by hand, and this one is waiting. Approve it "
        + "under Machines in the admin console and the connection starts on its own."
      link = Pages.machines
      key = "device-approval"

    case .httpsNotEnabled(let url):
      title = "Enable HTTPS certificates for your tailnet"
      body =
        "Tailscale serves this server over HTTPS, which needs certificates enabled once "
        + "for your whole tailnet. Open the link, turn on HTTPS Certificates, and the "
        + "connection starts on its own."
      link = url ?? Pages.https
      key = "https.\(url?.lastPathComponent ?? "")"

    case .funnelNotEnabled(let url):
      title = "Enable Tailscale Funnel for this Mac"
      body =
        "Publishing to the internet needs Funnel enabled for this Mac in your tailnet's "
        + "access policy. Open the link and allow it, and the connection starts on its "
        + "own — or choose \"Only devices on my tailnet\" on the Tailscale page instead."
      link = url ?? Pages.funnel
      key = "funnel.\(url?.lastPathComponent ?? "")"
    }

    var actions: [AlertAction] = []
    if let link { actions.append(.openURL(link)) }
    actions.append(.openSettings(.settings))

    await host.alerts.raise(
      UserAlert(
        severity: .warning,
        title: title,
        body: body,
        source: "Connection",
        actions: actions,
        dedupeKey: "proxy.tailscale.attention.\(key)",
        // Re-raised by the provider whenever the step is still pending after a restart,
        // so the fresh notice replaces this one rather than sitting behind it.
        isDurable: false
      )
    )
  }
}
