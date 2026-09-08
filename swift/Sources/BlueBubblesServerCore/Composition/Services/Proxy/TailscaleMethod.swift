//  TailscaleMethod
//  Tailscale, driven through the managed `tailscaled` and its `tailscale` companion.

import BBBuiltIns
import BBPrivateAPIContract
import BBProxy
import BBServiceKit
import BBSettings
import Foundation

/// Tailscale: the connection method whose setup can wait on a person.
///
/// Thin, like ngrok's and Cloudflare's, because the waiting and the asking both live in the
/// provider — see `TailscaleTunnel` — and reach the person through the same
/// `ProxyObserver.attentionRequired` every connection method has. All that is decided here
/// is what the settings page said and where the daemon keeps its state.
enum TailscaleMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.tailscale }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let daemonPath = await host.toolExecutable() else { return nil }

    // The CLI is how the daemon is signed in and told what to serve; neither works alone.
    // Declared as the daemon's companion, so the tool manager resolves it from the same
    // install — and a daemon without it, from an install someone pointed at by hand, is
    // reported rather than guessed around.
    guard let cliPath = await host.companionExecutable(named: "tailscale") else {
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
      socketPath: TailscaleOptions.socketPath(
        preferring: stateDirectory, fallback: NSTemporaryDirectory()
      )
    )

    return Tunnels.tailscale(
      daemonExecutablePath: daemonPath,
      cliExecutablePath: cliPath,
      port: await host.forwardedPort(),
      options: options
    )
  }
}
