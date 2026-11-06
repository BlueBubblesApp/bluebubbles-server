//  SettingsRegistry+SwiftOnly
//  The settings the Electron server did not have, all default-off: the auth mode, the update
//  feed, the event codec, the log level, rate limiting, local-network trust, ntfy and the
//  trusted proxies.
//
//  Its own file so a reader of what this server adds to the Electron vocabulary opens these
//  declarations and not the ones every install already had. The lists that make a setting
//  exist (`Settings.renderable`, `Settings.hidden`) stay in `SettingsRegistry.swift`.

import Foundation

extension Settings {

  // MARK: - New in the Swift server (all default-off)

  public static let authMode = Setting<AuthMode>(
    "auth_mode", default: .password,
    application: .composition,
    presentation: .init(
      label: "Authentication",
      help:
        "Password in the query string is the default and the only mode existing clients support.",
      section: .security,
      control: .picker(
        options: AuthMode.allCases.map { .init(value: $0.rawValue, label: $0.rawValue) })
    )
  )

  /// Where the update check reads from.
  ///
  /// Shown, not editable. This is where the app fetches code it will run, so it is not a
  /// row to mistype; a release channel, or a local feed while developing the updater, is
  /// set from the CLI (`--set update_feed_url=…`), and that friction is the point. Both
  /// readers (`UpdateChecker` behind `GET /server/update/check`, and Sparkle through
  /// `SparkleUpdater`) take it from here, so the API and the installer cannot disagree about
  /// which feed is current.
  public static let updateFeedURL = Setting<String>(
    "update_feed_url", default: UpdateFeed.defaultURL,
    presentation: .init(
      label: "Update feed",
      help: "The Sparkle appcast this server checks for updates. Set from the command line "
        + "to point a development build at a local feed.",
      section: .advanced, control: .readOnly
    )
  )

  public static let eventPayloadCodec = Setting<PayloadCodecID>(
    "event_payload_codec", default: .legacyV1,
    application: .composition,
    presentation: .init(
      label: "Event Payload Format",
      help: "The server's preference ceiling. Each client negotiates down from it.",
      section: .security,
      control: .picker(
        options: PayloadCodecID.allCases.map { .init(value: $0.rawValue, label: $0.rawValue) })
    )
  )

  public static let logLevel = Setting<String>(
    "log_level", default: "info",
    presentation: .init(
      label: "Log Level", section: .debug,
      control: .picker(options: [
        .init(value: "trace", label: "Trace"), .init(value: "debug", label: "Debug"),
        .init(value: "info", label: "Info"), .init(value: "warning", label: "Warning"),
        .init(value: "error", label: "Error"),
      ])))

  // Access control. Failure-only, so a client polling with valid credentials is
  // never throttled.
  /// The master switch for the automatic half of access control: counting failed logins,
  /// blocking an address that crosses the threshold, and throttling an unidentifiable
  /// source. Rate limiting and IP blocking are one feature: blocking is what the rate
  /// limiter does once the threshold is crossed, so they share one toggle.
  ///
  /// On by default, and off is a supported configuration: a LAN-only install, or one behind
  /// a proxy that already does this, gains nothing from it and can lose clients to a false
  /// positive. Turning it off does NOT lift a block an administrator set by hand.
  public static let rateLimitEnabled = Setting<Bool>(
    "rate_limit_enabled", default: true,
    presentation: .init(
      label: "Rate Limiting & IP Blocking",
      help: "Count failed logins and temporarily block addresses that keep failing. "
        + "Turning this off stops all automatic blocking; addresses you blocked "
        + "yourself stay blocked.",
      section: .security, control: .toggle
    ))
  public static let rateLimitFailureThreshold = Setting<Int>(
    "rate_limit_failures", default: 10,
    presentation: .init(
      label: "Failures Before Block", section: .security, control: .number(range: 3...1000),
      // Counting failures IS the automatic half, and it is the half the toggle above
      // governs: with it off, `AccessControl.recordFailure` returns before the threshold is
      // ever compared.
      requires: rateLimitEnabled.key))

  // `trustLocalNetwork` below deliberately does NOT hang off `rateLimitEnabled`, however
  // much it reads like it should. It writes the private ranges into the ALLOWLIST, and
  // `AccessControl.evaluate` consults `isAlwaysAllowed` before it consults
  // `policy.isEnabled`, so with rate limiting switched off this still exempts a LAN address
  // from a block an administrator set by hand. Greying it out would leave a control that
  // still does something looking dead.
  public static let rateLimitBlockSeconds = Setting<Int>("rate_limit_block_seconds", default: 900)
  /// Whether a device on your own network can be auto-blocked for failed logins.
  ///
  /// **Defaults ON, and what that does NOT do is the point: it never bypasses the password.**
  /// Authentication runs in two halves (`AuthenticationStage.admit`
  /// then `verifyCredential`) and this touches only the first: the allowlist is read by
  /// `AccessControl.evaluate` and `recordFailure` and by nothing in the credential chain. A
  /// LAN client still presents the server password like any other, and a wrong one is still
  /// a 401. All this removes is the automatic LOCKOUT.
  ///
  /// It defaults on because the failure it prevents is invisible and the protection it drops
  /// is thin. Loopback can never be blocked (`ProxyTrustPolicy.permanentAllowlist`), so with
  /// this off a phone on the same desk locks itself out after ten bad passwords while `curl`
  /// on the Mac keeps working — and a blocked caller receives a 401, deliberately identical
  /// to a wrong password, so nothing on the wire says what happened. Reproduced exactly: ten
  /// wrong passwords from the LAN address, then the CORRECT password answered 401 from the
  /// LAN and 200 from loopback. It is the shape of a support report nobody can diagnose.
  ///
  /// Against that, the reference has no rate limiter, no blocklist and no such setting at
  /// all, so an install with this on is still strictly more hardened than every v1 server
  /// ever shipped. What it costs is that a hostile device already inside your network gets
  /// unlimited guesses at the password, which is the reason to turn it off and why the
  /// switch is a plain toggle on the Security page rather than something buried.
  public static let trustLocalNetwork = Setting<Bool>(
    // DEFAULT OFF, which is what `docs/AUTH.md` and `AccessControl.trustLocalNetwork`'s own
    // comment ("a LAN is not automatically friendly") both already said while this said
    // `true`. On, it allowlists the private ranges, and an allowlisted address is never
    // counted and never blocked — so the failure budget for anything on the LAN, including
    // anything that has merely joined the Wi-Fi, was unlimited by default.
    "trust_local_network", default: false,
    presentation: .init(
      label: "Trust My Local Network",
      help: "Devices on your own network are never locked out for failed logins. They still "
        + "need the server password. Turn this off to rate-limit them too, if something on "
        + "your network might try to guess it.",
      section: .security, control: .toggle
    ))
  // ntfy's OLD configuration, kept only so an existing install's values can be found.
  //
  // ntfy is `BuiltInManifests.ntfy` now, an integration of its own, and its configuration is
  // four manifest fields in its own namespace. These four are `isInternal`, so no page draws
  // them; the readers left are `NtfySettingsAdoption.run`, which moves whatever is here
  // into the new namespace once and then clears it, and the in-use check in
  // `ServerComposition+ServiceSettings.swift`, which has to see a topic that has not moved yet.
  //
  // Not deleted, and that is the point: a declaration removed is a value that stays in the
  // database, unread and unreachable, while the service reports itself unconfigured. That is
  // the exact failure `ServiceMigration.swift` opens by describing. They come out when an
  // install that could still be carrying them is no longer plausible.
  public static let ntfyTopic = Setting<String>(
    "ntfy_topic", default: "", isConfidential: true,
    presentation: .init(
      label: "ntfy Topic",
      help: "Moved to the ntfy integration.",
      section: .notifications, control: .textField,
      isInternal: true
    ))
  public static let ntfyServer = Setting<String>(
    "ntfy_server", default: "https://ntfy.sh",
    presentation: .init(
      label: "ntfy Server",
      help: "Moved to the ntfy integration.",
      section: .notifications, control: .textField,
      isInternal: true
    ))
  /// Which events reached the ntfy topic, comma-separated. `*` means everything.
  public static let ntfyEvents = Setting<String>(
    "ntfy_events", default: "*",
    presentation: .init(
      label: "ntfy Events",
      help: "Moved to the ntfy integration.",
      section: .notifications, control: .textField,
      isInternal: true
    ))

  /// Secret: an ntfy access token grants publish rights to the topic.
  public static let ntfyToken = Setting<String>(
    "ntfy_token", default: "", isSecret: true,
    presentation: .init(
      label: "ntfy Access Token",
      help: "Moved to the ntfy integration.",
      section: .notifications, control: .secureField,
      isInternal: true
    ))

  /// Comma-separated addresses or CIDR blocks whose `X-Forwarded-For` header is believed.
  ///
  /// Empty by default, which trusts loopback only: correct for the managed tunnels, since
  /// ngrok, cloudflared, zrok and tailscaled all run on this machine and connect over
  /// 127.0.0.1.
  ///
  /// It matters for the deployment that is NOT bundled: an nginx or Caddy in front of the
  /// server on another host. There every request arrives from one address, so without this
  /// the whole user base shares a single failure counter and ten bad passwords from any one
  /// person locks out everybody: a self-inflicted outage far worse than the brute-force
  /// attempt it was reacting to.
  public static let trustedProxies = Setting<String>(
    "trusted_proxies", default: "",
    presentation: .init(
      label: "Trusted Reverse Proxies",
      help: "Addresses or CIDR blocks allowed to set X-Forwarded-For. "
        + "Leave empty unless the server sits behind your own reverse proxy.",
      section: .security, control: .textField
    ))
}
