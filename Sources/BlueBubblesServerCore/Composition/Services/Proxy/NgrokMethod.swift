//  NgrokMethod
//  The ngrok tunnel, driven through the managed `ngrok` binary.

import BBBuiltIns
import BBProxy
import BBServiceKit
import BBSettings

enum NgrokMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.ngrok }

  static func makeProvider(_ host: ProxyHost) async -> ProxyStart {
    guard let path = await host.toolExecutable() else { return await host.toolMissing() }

    let token = await host.own("auth_token").trimmingCharacters(in: .whitespaces)
    // ngrok refuses to open any tunnel without one, and it says so in output nobody
    // reads. Reported here, where the remedy is a field on this page.
    guard !token.isEmpty else {
      return await host.needsAttention(
        title: "ngrok has no auth token",
        body: "ngrok will not open a tunnel without one. Paste the authtoken "
          + "from your ngrok dashboard on the ngrok page.",
        key: "token-missing"
      )
    }

    return .ready(
      Tunnels.ngrok(
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
          // list. Not an ngrok option; it is a fact about the origin ngrok forwards to.
          originUsesTLS: await host.originUsesTLS()
        ),
        ledger: host.daemonLedger
      ))
  }
}
