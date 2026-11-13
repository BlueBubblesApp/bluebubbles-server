//  BuiltInManifests
//  The built-in services, described in the same model a third-party plugin will use.
//
//  These are the seeded plugins. They ship enabled and are trusted with core entitlements,
//  and that is the ONLY difference: same manifest type, same validator, same entitlement
//  rules, same settings namespace scheme. That is not tidiness: it is the only way to know
//  the model is expressive enough. If the reverse proxies cannot be described here, no
//  third-party plugin will be describable either, and we would find that out after publishing
//  an API rather than before.
//
//  Three things the manifests say that an enum of connection methods could not: that the
//  tunnels are the same KIND of thing and
//  only one may run at a time; that every one of them needs to run a program, which is
//  exactly the permission a user should be told about; and that zrok's reserved-share fields
//  are meaningless unless a toggle above them is on.
//
//  The manifests themselves are declared by family: `BuiltInManifests+Tunnels.swift`,
//  `BuiltInManifests+Publishing.swift`, `BuiltInManifests+Sinks.swift`,
//  `BuiltInManifests+Core.swift` and `AuditLogManifest.swift`. This file holds the
//  identifiers, the two enablement sets and the list of every built-in.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBServiceKit
import BBSettings
import BBSystem

public enum BuiltInManifests {

  // MARK: - Identifiers

  public enum ID {
    public static let http = ServiceIdentifier("app.bluebubbles.core.http")
    public static let socket = ServiceIdentifier("app.bluebubbles.core.socket")
    public static let permissions = ServiceIdentifier("app.bluebubbles.core.permissions")
    public static let changeDetection = ServiceIdentifier("app.bluebubbles.core.change-detection")
    public static let contacts = ServiceIdentifier("app.bluebubbles.core.contacts")
    public static let privateAPI = ServiceIdentifier("app.bluebubbles.core.private-api")
    public static let scheduledMessages = ServiceIdentifier(
      "app.bluebubbles.core.scheduled-messages")
    public static let sleepPrevention = ServiceIdentifier("app.bluebubbles.core.sleep-prevention")
    public static let launchAtLogin = ServiceIdentifier("app.bluebubbles.core.launch-at-login")
    public static let toolUpdates = ServiceIdentifier("app.bluebubbles.core.tool-updates")
    public static let license = ServiceIdentifier("app.bluebubbles.core.license")
    public static let networkPath = ServiceIdentifier("app.bluebubbles.core.network-path")
    public static let networkRecovery = ServiceIdentifier(
      "app.bluebubbles.core.network-recovery")
    public static let messageSearch = ServiceIdentifier("app.bluebubbles.core.message-search")
    public static let auditLog = ServiceIdentifier("app.bluebubbles.core.audit-log")

    public static let push = ServiceIdentifier("app.bluebubbles.sink.push")
    public static let webhooks = ServiceIdentifier("app.bluebubbles.sink.webhooks")
    public static let ntfy = ServiceIdentifier("app.bluebubbles.sink.ntfy")

    public static let proxyLAN = ServiceIdentifier("app.bluebubbles.proxy.lan")
    public static let proxyDynamicDNS = ServiceIdentifier("app.bluebubbles.proxy.dynamic-dns")
    public static let proxyNgrok = ServiceIdentifier("app.bluebubbles.proxy.ngrok")
    public static let proxyCloudflare = ServiceIdentifier("app.bluebubbles.proxy.cloudflare")
    public static let proxyZrok = ServiceIdentifier("app.bluebubbles.proxy.zrok")
    public static let proxyTailscale = ServiceIdentifier("app.bluebubbles.proxy.tailscale")
  }

  /// Services that stay running whatever `disabled_services` says.
  ///
  /// Permissions, which reports what macOS granted: there is nothing in it to disable.
  ///
  /// And the subscription, which has no OFF state a person could want. Without a key it
  /// already declines to run (`LicenseService.canRun`), so the switch gave a free install
  /// nothing. With a key, "off" meant one of two wrong things: switched off while running,
  /// the cached entitlement was never re-evaluated and paid features outlived the token;
  /// off at the next launch, the token on disk was never loaded and a paying customer was
  /// answered 402 with "no license" while their key sat in settings. The control a person
  /// actually has is the key: Remove on the Subscription page clears it, and with it the
  /// daily check-in. `LicenseRuntime` also primes itself from disk on first read, so the
  /// gate's answer does not depend on this service's schedule ever having run.
  ///
  /// The socket USED to be here, on the grounds that it is how a connected client is told
  /// anything at all. That is true and is not a reason: a REST-only server is a real
  /// deployment, and the HTTP API (which is strictly more essential to reachability) has
  /// always been switchable. What the socket needs is not permanence but an ORDER, which
  /// it now declares: it depends on the HTTP API, whose listener carries it.
  ///
  /// The HTTP API is the interesting case: switching it off stops the server serving, which
  /// is a thing an operator may genuinely want and is also the one switch that can leave a
  /// headless install unreachable. It is recoverable from the CLI:
  /// `bluebubbles-server --set disabled_services=`, and the app's own UI keeps working
  /// either way, because it talks to the interfaces in-process rather than over HTTP. The
  /// six reverse proxies and the socket declare a dependency on it, so switching it off
  /// takes them down with it rather than leaving an address that resolves to nothing.
  ///
  /// Enforced HERE rather than only in the app's Integrations screen, which is what makes
  /// it true of a settings value written by any other route: the settings API, the CLI's
  /// `--set`, or a hand-edited database.
  ///
  /// Message Search and Start at Login are here for a different reason from the first two:
  /// each is switched by a setting (`search_index_enabled`, `auto_start_method`) and starts
  /// whatever that says, because off is work (deleting the index, removing the login item). A
  /// name in `disabled_services` would be a second off state that stopped that work happening.
  public static let alwaysOn: Set<ServiceIdentifier> = [
    ID.permissions, ID.license, ID.messageSearch, ID.launchAtLogin,
  ]

  /// Built-ins that ship switched OFF, so a fresh install does not run them until somebody
  /// asks for one.
  ///
  /// Being compiled in is not a reason to be running. ntfy publishes to a third-party
  /// service that most installs do not use, and until this list existed every built-in was
  /// on by default — which was harmless while ntfy was inert without a topic, and stops
  /// being harmless the moment "enabled" is something a person reads off the Integrations
  /// page and believes.
  ///
  /// Seeded ONCE, into `disabled_services`, rather than being consulted on every read: the
  /// list means "what the user switched off", and a default folded into every read could
  /// never be switched back on. See `ServiceEnablement.seed(skipping:)`.
  ///
  /// The audit log is off for a different reason: it is a compliance feature that writes a
  /// row for every action and auth failure, and a home install gains nothing from the table
  /// growing. An operator who needs it turns it on, and `audit.recording_started` is the
  /// first thing it records.
  public static let disabledByDefault: Set<ServiceIdentifier> = [ID.ntfy, ID.auditLog]

  // MARK: - Every built-in

  /// Every built-in, for validation and for the UI.
  public static let all: [ServiceManifest] = [
    http, socket, permissions, changeDetection, messageSearch, contacts, privateAPI,
    scheduledMessages, sleepPrevention, launchAtLogin, toolUpdates,
    networkPath, networkRecovery,
    license,
    push, webhooks, ntfy,
    lan, dynamicDNS, ngrok, cloudflare, zrok, tailscale,
    auditLog,
  ]
  /// The keys no service may be granted: the core secrets and every built-in's secret
  /// fields. What a service's settings scope is checked against; see
  /// `ServiceManifest.secrets(core:of:)`.
  public static let secretKeys = ServiceManifest.secrets(core: Settings.secretKeys, of: all)

}
