//  NgrokMethod
//  The ngrok tunnel, driven through the managed `ngrok` binary.

import BBDiagnostics
import BBProxy
import BBServiceKit
import BBSettings

enum NgrokMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.ngrok }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let path = await host.toolExecutable() else { return nil }

    let token = await host.own("auth_token").trimmingCharacters(in: .whitespaces)
    // ngrok refuses to open any tunnel without one, and it says so in output nobody
    // reads. Reported here, where the remedy is a field on this page.
    guard !token.isEmpty else {
      await host.context.alerts.raise(
        UserAlert(
          severity: .warning,
          title: "ngrok has no auth token",
          body: "ngrok will not open a tunnel without one. Paste the authtoken "
            + "from your ngrok dashboard on the ngrok page.",
          source: "Connection",
          actions: [.openSettings(section: "settings")],
          dedupeKey: "proxy.ngrok.token-missing"
        )
      )
      return nil
    }

    return Tunnels.ngrok(
      executablePath: path,
      port: await host.forwardedPort(),
      options: NgrokOptions(
        authToken: token,
        region: await host.ownOrDefault("region", NgrokOptions.Default.region),
        domain: await host.own("custom_domain"),
        hostHeader: await host.own("host_header"),
        disableInspection: await host.ownFlag("disable_inspection"),
        trafficPolicyFile: await host.own("traffic_policy_file"),
        verboseLogging: await host.ownFlag("verbose_logging"),
        // Declared on the manifest, so this read is allowed and is on the permissions
        // list. Not an ngrok option — it is a fact about the origin ngrok forwards to.
        originUsesTLS: await host.scoped.getOrDefault(Settings.useCustomCertificate)
      )
    )
  }
}
