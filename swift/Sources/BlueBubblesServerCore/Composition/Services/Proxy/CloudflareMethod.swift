//  CloudflareMethod
//  Cloudflare quick and named tunnels, driven through the managed `cloudflared` binary.

import BBBuiltIns
import BBPrivateAPIContract
import BBProxy
import BBServiceKit
import BBSettings
import Foundation

enum CloudflareMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.cloudflare }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let path = await host.toolExecutable() else { return nil }

    let mode = CloudflareOptions.Mode(rawValue: await host.ownOrDefault("mode", "quick")) ?? .quick
    let hostname = await host.own("hostname").trimmingCharacters(in: .whitespaces)
    let imported = await host.own("config_file").trimmingCharacters(in: .whitespaces)

    // Both named modes route a hostname the user owns, and cloudflared never prints it —
    // so without being told, there is nothing to publish to clients. Refusing here beats
    // starting a tunnel whose address this server cannot name.
    if mode != .quick, hostname.isEmpty {
      await host.complain(
        title: "Cloudflare needs the hostname your tunnel uses",
        body: "cloudflared does not report the address of a tunnel you configured "
          + "yourself. Enter it as the Public Hostname on the Cloudflare Tunnel page.",
        key: "hostname-missing"
      )
      return nil
    }

    var token = ""
    if mode == .token {
      // Read from the Keychain, because the field is declared `isSecret`. It goes no
      // further than `CloudflareOptions.environment` from here.
      token = await host.own("token").trimmingCharacters(in: .whitespaces)
      if token.isEmpty {
        await host.complain(
          title: "Cloudflare has no tunnel token",
          body: "Paste the token from your tunnel's page in the Cloudflare Zero "
            + "Trust dashboard on the Cloudflare Tunnel page.",
          key: "token-missing"
        )
        return nil
      }
    }

    if mode == .configuration {
      // A file the user pointed at but which is no longer there is reported, not
      // silently swapped for the generated one. Falling back quietly would start a quick
      // tunnel under a configuration the user believes is running theirs, publish a
      // trycloudflare address nobody expects, and give no hint why.
      guard !imported.isEmpty, FileManager.default.isReadableFile(atPath: imported) else {
        await host.complain(
          title: "The Cloudflare configuration file cannot be read",
          body: imported.isEmpty
            ? "Choose the `config.yml` for your tunnel on the Cloudflare Tunnel page."
            : "This server cannot read \(imported). Choose the file again on the "
              + "Cloudflare Tunnel page, or switch back to a quick tunnel.",
          key: "config-unreadable"
        )
        return nil
      }
    }

    // Their file when they supplied one; ours otherwise. Never cloudflared's own default
    // location — see `generatedConfigFile`.
    let configFile = mode == .configuration ? imported : Self.generatedConfigFile()
    guard let configFile else { return nil }

    return Tunnels.cloudflare(
      executablePath: path,
      port: await host.forwardedPort(),
      options: CloudflareOptions(
        configFile: configFile,
        mode: mode,
        token: token,
        hostname: hostname,
        transportProtocol: await host.ownOrDefault(
          "protocol", CloudflareOptions.Default.transportProtocol
        ),
        edgeIPVersion: await host.ownOrDefault(
          "edge_ip_version", CloudflareOptions.Default.edgeIPVersion
        ),
        region: await host.ownOrDefault("region", CloudflareOptions.Default.region),
        verboseLogging: await host.ownFlag("verbose_logging"),
        // Declared on the manifest, so this read is allowed and is on the permissions
        // list. Not a Cloudflare option and not offered as one — see `CloudflareOptions`.
        originUsesTLS: await host.scoped.getOrDefault(Settings.useCustomCertificate)
      )
    )
  }

  /// This service's own, deliberately empty, cloudflared configuration file.
  ///
  /// It exists so that cloudflared can be pointed AWAY from `~/.cloudflared/config.yml`.
  /// Cloudflare documents quick tunnels as unsupported when cloudflared finds a configuration
  /// of its own, so a user who runs cloudflared for something else had this server's default
  /// connection method fail with nothing on screen to explain it.
  ///
  /// Rewritten on every start rather than only when absent: the cost is one small write, and
  /// the alternative is trusting a file on disk that anything could have edited since.
  private static func generatedConfigFile() -> String? {
    let directory = SocketLocation.supportDirectory + "/cloudflared"
    let path = directory + "/config.yml"
    let contents = """
      # Written by BlueBubbles. Do not edit.
      #
      # Deliberately empty. Its only job is to be the file cloudflared reads INSTEAD of
      # ~/.cloudflared/config.yml, which would otherwise stop quick tunnels working for
      # anyone who runs cloudflared for something else. Everything this server configures
      # is passed on the command line.
      #
      # To run a tunnel of your own, import its configuration on the Cloudflare Tunnel
      # page rather than editing this file — it is overwritten every time the tunnel
      # starts.

      """
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
      try contents.write(toFile: path, atomically: true, encoding: .utf8)
      return path
    } catch {
      return nil
    }
  }
}
