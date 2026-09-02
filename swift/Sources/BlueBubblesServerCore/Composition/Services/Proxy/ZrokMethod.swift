//  ZrokMethod
//  The zrok tunnel: the one connection method with a SETUP as well as a configuration.

import BBBuiltIns
import BBProxy
import BBServiceKit
import BBSettings
import BBSystem

/// zrok, which is the only connection method with a SETUP as well as a configuration.
///
/// cloudflared and ngrok are handed a credential and start. zrok is not: this Mac has to be
/// enabled against a zrok account first, and a share that keeps its address has to be reserved
/// by a separate command that hands back a token to remember. The TypeScript `ZrokManager` did
/// all of that; the port did none of it, so the Account Token field on the zrok page was
/// collected, stored, and read by nothing — the tunnel ran as an anonymous share or not at all.
///
/// The one-shot half lives in `ZrokEnvironment`. This is where it is decided WHICH of those
/// commands need to run, which is a question only the stored configuration can answer.
enum ZrokMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.zrok }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    guard let path = await host.toolExecutable() else { return nil }

    let accountToken = await host.own("account_token").trimmingCharacters(in: .whitespaces)
    guard !accountToken.isEmpty else {
      await host.complain(
        title: "zrok has no account token",
        body: "zrok cannot share anything until this Mac is linked to a zrok account. "
          + "Create a free account at zrok.io and paste the account token on the "
          + "zrok page.",
        key: "account-token-missing"
      )
      return nil
    }

    var options = ZrokOptions(
      verboseLogging: await host.ownFlag("verbose_logging"),
      // Declared on the manifest, so this read is allowed and is on the permissions
      // list. Not a zrok option — it is a fact about the origin zrok proxies to.
      originUsesTLS: await host.scoped.getOrDefault(Settings.useCustomCertificate),
      apiEndpoint: await host.own("api_endpoint")
    )

    let environment = ZrokEnvironment(
      executablePath: path,
      // The same environment for every zrok invocation — the share, the enable, the
      // reserve — so a self-hosted controller cannot be reached by some of them and not
      // by others.
      environment: options.environment,
      logger: host.context.logger
    )

    do {
      if try await environment.enableIfNeeded(accountToken: accountToken) {
        host.context.logger.info("Linked this Mac to a zrok account")
      }
    } catch let error as ZrokError {
      await host.complain(
        title: error == .invalidAccountToken
          ? "zrok rejected the account token"
          : "zrok could not be set up on this Mac",
        body: error == .invalidAccountToken
          ? "Check the account token on the zrok page against the one on your zrok "
            + "account, and paste it again."
          : "zrok said: \(error.message)",
        key: "enable-failed"
      )
      return nil
    } catch {
      return nil
    }

    let port = await host.forwardedPort()
    let endpoint = options.target(port: port)

    if await host.ownFlag("reserve_tunnel") {
      guard
        let token = await reservedShareToken(
          host: host,
          using: environment, endpoint: endpoint, backendMode: options.backendMode
        )
      else { return nil }
      options.reservedToken = token
    } else {
      // Reserving is off, so anything reserved earlier is now unused. Letting go of it
      // is what the TypeScript server did, and leaving it would quietly go on occupying
      // a name on the user's account that they can no longer see from here.
      await forgetReservedShare(host: host, using: environment)
    }

    return Tunnels.zrok(executablePath: path, port: port, options: options)
  }

  // MARK: - Reserved shares

  /// The token of the reserved share this server should use, reserving one if it must.
  ///
  /// Returns nil only when it could not get one AND has said so.
  private static func reservedShareToken(
    host: ProxyHost,
    using environment: ZrokEnvironment,
    endpoint: String,
    backendMode: String
  ) async -> String? {
    let storedToken = await host.own("reserved_token").trimmingCharacters(in: .whitespaces)
    let desiredName = await host.own("reserved_name").trimmingCharacters(in: .whitespaces)

    // Shares belonging to THIS Mac. The filter is not optional: one zrok account can hold
    // several machines' environments, and without it two servers sharing an account would
    // each adopt the other's share.
    let existing: [ZrokShare]
    do {
      existing = try await environment.shares(ownedBy: SystemInfo.computerIdentifier())
    } catch {
      // zrok could not be asked. Reserving anyway would create a duplicate every time
      // the network is down, so the stored token is used as-is and the problem is left
      // to the tunnel itself to report.
      host.context.logger.warning(
        "Could not read the zrok share list; using the stored share",
        metadata: ["error": .string(String(describing: error))]
      )
      guard !storedToken.isEmpty else {
        await host.complain(
          title: "zrok could not be reached",
          body: "This server needs to ask zrok about your reserved shares before it "
            + "can start one, and that request failed. Check this Mac's internet "
            + "connection, or switch reserving off to use a throwaway share.",
          key: "overview-failed"
        )
        return nil
      }
      return storedToken
    }

    // A share reserved with `--unique-name X` HAS `X` as its token, which is what makes
    // "the name changed" detectable at all.
    let wantedToken = desiredName.isEmpty ? storedToken : desiredName

    if !wantedToken.isEmpty,
      let share = existing.first(where: { $0.token == wantedToken }),
      share.matches(endpoint: endpoint, backendMode: backendMode)
    {
      // Already exactly what is wanted. Written back only when it differs, because every
      // settings write is broadcast and this service restarts on its own keys — an
      // unconditional write here would restart the tunnel on every launch, forever.
      if storedToken != share.token {
        await remember(reservedToken: share.token, host: host)
      }
      return share.token
    }

    // Whatever is stored is stale — the port moved, the name changed, or the share was
    // deleted from the zrok dashboard. Let go of it before reserving its replacement, or
    // the account accumulates one abandoned share per change.
    if !storedToken.isEmpty {
      await forgetReservedShare(host: host, using: environment)
    }

    do {
      let token = try await environment.reserve(
        endpoint: endpoint, name: desiredName, backendMode: backendMode
      )
      await remember(reservedToken: token, host: host)
      host.context.logger.info("Reserved a zrok share")
      return token
    } catch let error as ZrokError {
      await host.complain(
        title: "zrok could not reserve a share",
        body: "zrok said: \(error.message)",
        key: "reserve-failed"
      )
      return nil
    } catch {
      return nil
    }
  }

  /// Releases the stored reserved share and forgets its token.
  ///
  /// Honours "Keep Reserved Shares", which exists because deleting something from a user's
  /// zrok account is not a thing a toggle on a settings page should do silently.
  private static func forgetReservedShare(host: ProxyHost, using environment: ZrokEnvironment)
    async
  {
    let token = await host.own("reserved_token").trimmingCharacters(in: .whitespaces)
    guard !token.isEmpty else { return }

    if await host.ownFlag("keep_share") {
      host.context.logger.info("Leaving a reserved zrok share in place, as configured")
    } else {
      await environment.release(token: token)
    }
    // Forgotten either way: this server is no longer using it, and a token left behind is
    // one that would be adopted again the next time reserving is switched on.
    await remember(reservedToken: "", host: host)
  }

  /// Persists the reserved share token, or says why it could not.
  ///
  /// A token that fails to persist is a share this server will not recognise as its own
  /// next launch — it will reserve another, and the account collects orphans. Logged at
  /// error so the leak has a cause on record.
  private static func remember(reservedToken token: String, host: ProxyHost) async {
    do {
      try await host.scoped.setOwn(token, field: "reserved_token")
    } catch {
      host.context.logger.error(
        "Could not save the reserved zrok share token",
        metadata: ["error": .string(String(describing: error))])
    }
  }

}
