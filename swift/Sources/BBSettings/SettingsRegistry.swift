//  SettingsRegistry
//  Every setting, declared once with its type, default, secrecy and presentation.
//
//  Keys are UNCHANGED from the Electron server, and renaming one is a breaking change: it
//  orphans the row a user's value already lives in, and it breaks both the config-file name
//  and the mapping `LegacyConfigMigration` reads the Electron `config.db` with. They are not
//  wire names — nothing serves the settings map to a client. See `Setting.key`.
//
//  Two things this file fixes by existing:
//    - `start_delay` is a real Double. It is currently defaulted to the STRING "0.0" with a
//      comment explaining that a numeric default would be misread as a boolean.
//    - Secrets are declared as such, so they route to the Keychain and are redacted in
//      diagnostics automatically rather than at each call site.
//
//  See `.claude/docs/database.md`.

import Foundation
import Logging

public enum AutoStartMethod: String, SettingValue, CaseIterable, Sendable {
  case none, unset
  case loginItem = "login-item"
  case launchAgent = "launch-agent"
  public static var typeTag: String { "string" }

  /// What a user should see. The raw values are storage, and two of them — `none` and
  /// `unset` — are the same answer to a person.
  public var label: String {
    switch self {
    case .none, .unset: "Don't start automatically"
    case .loginItem: "When I log in"
    case .launchAgent: "When I log in (background agent)"
    }
  }

  /// The options a picker offers.
  ///
  /// `unset` is deliberately absent: it is a legacy sentinel meaning "never decided", and
  /// offering it would let someone choose a value that means nothing. Existing rows holding
  /// it still parse and read as off.
  public static var choices: [AutoStartMethod] { [.none, .loginItem, .launchAgent] }
}

/// Authentication mode. `password` is the default and, per the compatibility contract, the
/// only active mechanism unless deliberately changed.
public enum AuthMode: String, SettingValue, CaseIterable, Sendable {
  case password, token, both
  public static var typeTag: String { "string" }
}

/// Event payload format. `legacyV1` is byte-identical to today's output.
public enum PayloadCodecID: String, SettingValue, CaseIterable, Sendable {
  case legacyV1 = "legacy-v1"
  case referenceV2 = "reference-v2"
  case sealedV2 = "sealed-v2"
  public static var typeTag: String { "string" }
}

public enum Settings {

  // MARK: - Connection

  public static let socketPort = Setting<Int>(
    "socket_port", default: 1234,
    presentation: .init(
      label: "Local Port", section: "Connection", control: .number(range: 1...65535))
  )

  /// The address clients use, as PUBLISHED by whichever connection method is running.
  ///
  /// An OUTPUT, not an input, and it was rendered as a text field — which made it both. The
  /// connection method writes it on every (re)connect, so a typed value survives only until
  /// the next publish; and because the field saved per keystroke, typing into it announced
  /// a partial address to Firebase once per character. A corpus of that looks like
  /// `server_address = "d"`.
  ///
  /// Where it actually comes from:
  ///   - a tunnel (ngrok, Cloudflare, zrok) — the address that tunnel was assigned;
  ///   - Local Network — this Mac's chosen or automatic LAN address plus `socket_port`;
  ///   - Custom URL — echoing back the URL entered on that method's own page.
  ///
  /// Every one of those has its own editable field on its own page. This is the result.
  public static let serverAddress = Setting<String>(
    "server_address", default: "",
    presentation: .init(
      label: "Server Address",
      help: "Published by the connection method below. To change it, change that.",
      section: "Connection", control: .readOnly)
  )

  public static let password = Setting<String>(
    "password", default: "", isSecret: true,
    // The entropy policy runs HERE, on write, and nowhere else. Validating on the auth
    // path instead would lock out every client that already holds a weak password the
    // moment the server updated, which is why `PasswordPolicy` is documented as a
    // set-time rule. An empty value is exempt: it is the shipped default and the state a
    // fresh install starts in, so rejecting it would make the server unconfigurable.
    validate: { candidate in
      guard !candidate.isEmpty else { return }
      try PasswordPolicy().validate(candidate)
    },
    presentation: .init(
      label: "Server Password",
      help: "Clients authenticate with this. Changing it disconnects connected clients.",
      // `canGenerate` is not a convenience. `PasswordPolicy.Rejection.tooPredictable` tells
      // the user to "use Generate", and that sentence is shown wherever a password is
      // rejected — including this row, which had no such button. Advice naming a control
      // that is not there is worse than no advice.
      section: "Connection", control: .secureField, canGenerate: true
    )
  )

  /// Which connection-method service is enabled.
  ///
  /// A service IDENTIFIER, not an enum case. That is the change that lets a third-party
  /// tunnel exist at all: an enum is compiled into this binary and a plugin cannot add a
  /// case to it, so as long as the choice was an enum, "connection method" was permanently
  /// closed to extension. Now it names a service in the exclusive `reverse-proxy` category,
  /// and the registry starts whichever one matches.
  ///
  /// Rendered by a bespoke view because the options are the INSTALLED services, which is
  /// runtime data — the same reason the network pickers are `.custom`.
  public static let connectionMethod = Setting<String>(
    "connection_method", default: "app.bluebubbles.proxy.cloudflare",
    presentation: .init(
      label: "Connection Method",
      help: "How clients reach this server.",
      section: "Connection", control: .custom
    )
  )

  /// Whether this server terminates TLS itself.
  ///
  /// Off by default, and that is right for most installs: ngrok, cloudflared and zrok all
  /// terminate TLS at their edge, and a second layer inside the tunnel buys nothing.
  ///
  /// It matters for the deployment that has no tunnel — dynamic DNS, or a port forwarded
  /// straight to this Mac — where the alternative is message content in plaintext across
  /// the internet. Turning it on uses the certificate imported on the Security page, or
  /// generates a self-signed one if there is none.
  public static let useCustomCertificate = Setting<Bool>(
    "use_custom_certificate", default: false,
    presentation: .init(
      label: "Serve over HTTPS",
      help: "Terminate TLS on this Mac. Leave off if a tunnel or reverse proxy already "
        + "does it. Import your certificate on the Security page.",
      section: "Connection", control: .toggle
    )
  )

  // MARK: - Connection-method credentials
  //
  // There are none here any more, and that is the point. ngrok's auth token, zrok's account
  // and reserved-share tokens and the rest now live in each service's OWN namespace,
  // declared by its manifest — `app.bluebubbles.proxy.zrok.account_token` rather than
  // `zrok_token`. A core registry listing every service's credentials is exactly the
  // arrangement that made "which settings may this service touch?" unanswerable.

  // MARK: - Private API

  public static let enablePrivateAPI = Setting<Bool>(
    "enable_private_api", default: false,
    presentation: .init(
      label: "Private API",
      help:
        "Enables reactions, edit/unsend, typing indicators and group management. Requires SIP to be disabled.",
      section: "Messages", control: .toggle
    )
  )
  /// The FaceTime helper, injected into FaceTime.app.
  ///
  /// A real setting rather than a developer feature flag, and the sibling of the Messages
  /// toggle above: it turns a capability on for a user, and turning it on injects a helper
  /// and mounts routes exactly as `enable_private_api` does.
  public static let enableFaceTimePrivateAPI = Setting<Bool>(
    "enable_ft_private_api", default: false,
    presentation: .init(
      label: "FaceTime Private API",
      help: "Enables FaceTime link generation, outgoing calls and call hand-off. "
        + "Injects a helper into FaceTime.app, so FaceTime is restarted and kept "
        + "running. Independent of the Messages Private API — either can be used "
        + "without the other. Requires SIP to be disabled.",
      section: "FaceTime", control: .toggle
    )
  )

  /// How long a server-created FaceTime link survives before the automatic sweep clears it.
  ///
  /// Only ever applies to links the SERVER minted — never one the user made in FaceTime.app,
  /// which the server records separately and never touches. Zero disables the sweep, leaving
  /// only the manual button.
  public static let faceTimeLinkTTLHours = Setting<Int>(
    "facetime_link_ttl_hours", default: 24,
    presentation: .init(
      label: "Clear server links after",
      help: "Hours before a link this server created is invalidated automatically. "
        + "Links you create yourself in FaceTime are never touched. 0 disables it.",
      section: "FaceTime", control: .number(range: 0...720)
    )
  )

  /// Answering an incoming call on a client's behalf.
  ///
  /// Separate from the toggle above because it is the most fragile of the FaceTime flows —
  /// it answers a LIVE call and must not drop until a client has really joined, or it hangs
  /// up on the caller. Off by default, and useless without `enable_ft_private_api`.
  public static let faceTimeIncomingHandoff = Setting<Bool>(
    "facetime_incoming_handoff", default: false,
    application: .composition,
    presentation: .init(
      label: "Incoming call hand-off",
      help: "Lets a client answer an incoming FaceTime call through the API and join "
        + "by link. Requires the FaceTime Private API.",
      section: "FaceTime", control: .toggle
    )
  )

  // There is deliberately NO setting for the helper transport, and adding one would be a
  // mistake worth naming here.
  //
  // `SocketTransport` is the only transport: a Unix socket inside the target app's own
  // container. The sandbox refuses a socket by LOCATION, not by kind — one in Application
  // Support or `/tmp` is refused, one inside the container connects — so there is no second,
  // closeable path and no legacy fallback to switch off. A setting here could only disable
  // the Private API outright.
  //
  // The concern such a setting would be reaching for — that a transport unable to identify
  // its peer lets any local process drive the Private API — is answered at connect time
  // instead: the peer's audit token is checked against the host app's code signature, and an
  // unverified peer is refused.
  //
  // See `.claude/docs/private-api.md` § "The sandbox, and where the socket must live".

  /// Where the helper dylib lives.
  ///
  /// Empty means "look inside the app bundle", which is where a released build finds it.
  /// A development server running from `.build` has no bundle to look in, so it points
  /// here — and it MUST point at an arm64e build on Apple Silicon, because Messages runs
  /// its arm64e slice and dyld silently declines a mismatched insert.
  public static let privateAPIHelperPath = Setting<String>(
    "private_api_helper_path", default: "",
    presentation: .init(
      label: "Helper dylib",
      help: "Leave empty to use the copy inside the app bundle.",
      section: "Private API", control: .path,
      // NOT USER-EDITABLE, but still a setting.
      //
      // Pointing this at the wrong file silently disables the Private API: dyld declines a
      // mismatched insert without a word, so the symptom is "reactions stopped working"
      // with nothing on screen connecting the two. A shipped install has exactly one
      // correct answer — the copy in its own bundle — so a file picker here is a way to
      // break it and nothing else.
      //
      // Still DECLARED, because a development build has no bundle to look in: running from
      // `.build`, this is the only way to name an arm64e helper. That case is served by
      // `--set private_api_helper_path=…` and the config file, both of which outrank the
      // stored value anyway, so hiding the field costs nothing.
      isInternal: true
    )
  )

  /// The FaceTime helper, injected into FaceTime.app rather than Messages.
  ///
  /// Separate from `privateAPIHelperPath` because they are DIFFERENT dylibs injected into
  /// DIFFERENT processes: FaceTime.app is its own sandboxed app with its own socket, and
  /// the Messages helper would be useless inside it. Same arm64e rule applies.
  public static let privateAPIFaceTimeHelperPath = Setting<String>(
    "private_api_facetime_helper_path", default: "",
    presentation: .init(
      label: "FaceTime helper dylib",
      help: "Leave empty to use the copy inside the app bundle.",
      section: "Private API", control: .path,
      // Hidden for the same reason as the Messages helper above.
      isInternal: true
    )
  )

  // MARK: - Behaviour

  /// A real Double. The Electron default is the string "0.0" purely to survive its own
  /// type coercion — the comment in constants.ts says so outright.
  public static let startDelay = Setting<Double>(
    "start_delay", default: 0,
    validate: { value in
      guard value >= 0, value <= 600 else {
        throw SettingsError.validationFailed(key: "start_delay", reason: "must be 0-600 seconds")
      }
    },
    presentation: .init(
      label: "Startup Delay", section: "Features", control: .number(range: 0...600))
  )

  /// How many chat.db reads may be in flight at once.
  ///
  /// **One by default, which is what this server has always done**: a single SQLite
  /// connection, every read serialised through it — HTTP routes, the change detector's poll
  /// and the app alike. `Tests/BBIMessageTests/ReadConcurrencyBenchmark.swift` measures what
  /// that costs. On a 40,000-message database, page queries stayed flat at ~26/second from
  /// one concurrent reader to sixteen; four readers reached ~95/second. The ceiling is real,
  /// and multi-client is the normal case here.
  ///
  /// The measured cost of raising it is small: four readers added about 2 MB. That is worth
  /// stating plainly, because "lower memory on old hardware" was the original justification
  /// for one connection and it had never been measured against the throughput it was buying.
  ///
  /// It stays at one by default anyway, because changing it changes behaviour on every
  /// existing install, and the numbers above come from one synthetic workload — deep-offset
  /// paging over a single chat — rather than from the field. Raising the default is a
  /// decision to take on evidence from real servers, not from this benchmark alone.
  public static let chatDatabaseReaders = Setting<Int>(
    "chat_db_readers", default: 1,
    application: .composition,
    presentation: .init(
      label: "Concurrent Database Readers",
      help: "How many message-database reads run at once. 1 is the safe default; raising it "
        + "helps when several clients are active, and costs memory per reader.",
      section: "Advanced", control: .number(range: 1...8))
  )

  /// Also a real Int. Under the current coercion a value of 0 or 1 comes back as a Bool.
  public static let dbPollInterval = Setting<Int>(
    "db_poll_interval", default: 1000,
    validate: { value in
      guard value >= 500 else {
        throw SettingsError.validationFailed(key: "db_poll_interval", reason: "minimum is 500ms")
      }
    },
    presentation: .init(
      label: "Poll Interval (ms)",
      help: "The shortest gap between two reads of the message database after a change is "
        + "noticed. Changes are detected by watching the file, not by polling; this only "
        + "spaces out reads during a burst.",
      section: "Advanced", control: .number(range: 500...30000))
  )

  public static let autoCaffeinate = Setting<Bool>(
    "auto_caffeinate", default: false,
    presentation: .init(label: "Keep Mac Awake", section: "Features", control: .toggle))
  /// Off by default. Registering a login item is something a user opts into — a server that
  /// silently starts itself after an install is a surprise, and an unwelcome one on a Mac
  /// someone else also uses.
  public static let autoStartMethod = Setting<AutoStartMethod>(
    "auto_start_method", default: .none,
    presentation: .init(
      label: "Start at Login",
      help: "Runs the server automatically when you log in to this Mac.",
      section: "Features",
      control: .picker(
        options: AutoStartMethod.choices.map { .init(value: $0.rawValue, label: $0.label) }
      )
    ))
  public static let startMinimized = Setting<Bool>(
    "start_minimized", default: false,
    presentation: .init(label: "Start Minimized", section: "Features", control: .toggle))
  public static let hideDockIcon = Setting<Bool>(
    "hide_dock_icon", default: false,
    presentation: .init(label: "Hide Dock Icon", section: "Features", control: .toggle))
  public static let dockBadge = Setting<Bool>(
    "dock_badge", default: true,
    presentation: .init(label: "Show Dock Badge", section: "Features", control: .toggle))
  public static let autoLockMac = Setting<Bool>(
    "auto_lock_mac", default: false,
    presentation: .init(label: "Lock Mac on Start", section: "Features", control: .toggle))
  public static let openFindMyOnStartup = Setting<Bool>(
    "open_findmy_on_startup", default: true,
    presentation: .init(label: "Open FindMy on Startup", section: "Features", control: .toggle))
  /// An HTML file served at `GET /` in place of the built-in page.
  ///
  /// Had no reader for the whole of the port — the route it configures did not exist — so
  /// an operator migrating from Electron lost their page silently. Both halves are wired
  /// now: `LandingHandlers` reads it, and this row is how it gets set.
  public static let landingPagePath = Setting<String>(
    "landing_page_path", default: "",
    presentation: .init(
      label: "Custom Landing Page",
      help: "An HTML file to serve at the server's root address instead of the default "
        + "page. Leave empty for the built-in one.",
      section: "Features",
      control: .path
    ))

  // MARK: - Updates and setup

  /// Off by default. An automatic check reaches out to the network on a schedule the user
  /// did not ask for; onboarding offers it, and the menu item works regardless.
  public static let checkForUpdates = Setting<Bool>(
    "check_for_updates", default: false,
    presentation: .init(
      label: "Check for Updates",
      help: "Looks for a new release once a day. You can always check by hand from the "
        + "BlueBubbles menu.",
      section: "Updates",
      control: .toggle
    ))
  /// Which network interface the HTTP API and socket listen on.
  ///
  /// `0.0.0.0` — every interface — is the default and matches the current server, which
  /// binds it unconditionally. The setting exists because that is not always what a user
  /// wants:
  ///
  /// - **With a tunnel, `127.0.0.1` is strictly better.** cloudflared, ngrok and zrok all
  ///   run on THIS machine and connect to the server locally, so binding wider exposes the
  ///   API to the whole LAN for no benefit at all. That is the one configuration where a
  ///   narrower bind costs nothing and removes an entire attack surface.
  /// - A Mac with several networks — a VPN, a lab VLAN, a virtualisation bridge — may want
  ///   to serve on exactly one of them.
  ///
  /// Stored as the address rather than an interface name because that is what `bind(2)`
  /// takes, and because an interface's address is the thing a user recognises. The UI
  /// offers the live list; `.custom` because the options depend on this machine and the
  /// generated settings screen only renders static ones.
  public static let bindAddress = Setting<String>(
    "bind_address", default: "0.0.0.0",
    presentation: .init(
      label: "Listen On",
      help: "Which network this server accepts connections from. "
        + "If you use a tunnel, Loopback is the safest choice.",
      section: "Connection", control: .custom
    )
  )

  // `lan_address` moved into the LAN connection method's own namespace
  // (`app.bluebubbles.proxy.lan.address`), declared by its manifest. A core registry listing
  // one service's configuration is the arrangement that made ownership unanswerable.

  public static let lastFcmRestart = Setting<Int>("last_fcm_restart", default: 0)

  /// Whether the Electron server's `config.db` has already been imported.
  ///
  /// The import writes unconditionally — it does not compare against defaults — so without
  /// this marker it would re-run on every launch and overwrite anything the user had since
  /// changed in the Swift app with the value the old server had. One-way and one-time by
  /// design: the Electron database is the source only until the Swift server owns the
  /// settings, which is the moment the first import finishes.
  ///
  /// No `presentation`: this is bookkeeping, not something to show a user.
  /// Services the user has switched off, as a comma-separated list of identifiers.
  ///
  /// A deny-list rather than an allow-list, so a service that ships in a later version is
  /// enabled by default — which is what "seeded plugin" means. An allow-list would leave
  /// every new built-in silently off for existing installs.
  public static let disabledServicesKey = "disabled_services"

  public static let legacyConfigImported = Setting<Bool>(
    "legacy_config_imported", default: false
  )

  /// The Firebase remote-restart channel.
  ///
  /// Defaults ON, because a shipping client has a restart button and turning it off by
  /// default would break it — the compatibility contract outranks the hardening here. What
  /// the switch is for is the user who never presses that button and would rather close
  /// vulnerability #4 outright: the document stays world-writable (locking it is what would
  /// break the button), so with this off nothing polls it and a forged command reaches
  /// nothing. With it on, the DoS is bounded rather than open — one restart an hour,
  /// freshness-checked, and alerted.
  ///
  /// No `presentation`: the control lives on the Firebase page, next to the project it
  /// governs, and is bound through `PushInterface.setRemoteRestartEnabled`. It carried a
  /// presentation for a "Notifications" section that never listed it, which made it look
  /// renderable while nothing rendered it.
  public static let remoteRestartEnabled = Setting<Bool>("remote_restart_enabled", default: true)

  /// Settings the Electron server had and this one does not read.
  ///
  /// Declared so `LegacyConfigMigration` can bring the row across and so the key stays
  /// reserved — a future setting must not reuse a name whose stored value means something
  /// else on an upgraded install. Nothing outside the migration reads any of these, and
  /// `LegacySettingsTests` asserts exactly that.
  public enum Legacy {
    public static let startViaTerminal = Setting<Bool>("start_via_terminal", default: false)
    /// The CLI's `--headless` flag is the real switch; this row is the Electron one.
    public static let headless = Setting<Bool>("headless", default: false)
    public static let disableGPU = Setting<Bool>("disable_gpu", default: false)
    public static let facetimeCalling = Setting<Bool>("facetime_calling", default: false)
    public static let autoInstallUpdates = Setting<Bool>("auto_install_updates", default: false)
    public static let tutorialIsDone = Setting<Bool>("tutorial_is_done", default: false)
    /// Force-disabled at startup by the Electron server; the sealed-v2 codec supersedes it.
    public static let encryptComs = Setting<Bool>("encrypt_coms", default: false)
    /// The Electron server's choice of injection mechanism. There is one here.
    public static let privateAPIMode = Setting<String>(
      "private_api_mode", default: "process-dylib")

    /// Every legacy row, for the coverage checks.
    public static let all: [AnySetting] = [
      startViaTerminal.erased, headless.erased, disableGPU.erased, facetimeCalling.erased,
      autoInstallUpdates.erased, tutorialIsDone.erased, encryptComs.erased,
      privateAPIMode.erased,
    ]
  }

  // MARK: - New in the Swift server (all default-off)

  public static let authMode = Setting<AuthMode>(
    "auth_mode", default: .password,
    application: .composition,
    presentation: .init(
      label: "Authentication",
      help:
        "Password in the query string is the default and the only mode existing clients support.",
      section: "Security",
      control: .picker(
        options: AuthMode.allCases.map { .init(value: $0.rawValue, label: $0.rawValue) })
    )
  )

  /// Where the update check reads from.
  ///
  /// Overridable so a beta channel can point at its own feed, and so the check can be
  /// aimed at a local file during development rather than at the network.
  public static let updateFeedURL = Setting<String>(
    "update_feed_url", default: UpdateFeed.defaultURL,
    presentation: .init(
      label: "Update feed",
      help: "The Sparkle appcast this server checks for updates.",
      section: "Advanced", control: .textField
    )
  )

  public static let eventPayloadCodec = Setting<PayloadCodecID>(
    "event_payload_codec", default: .legacyV1,
    application: .composition,
    presentation: .init(
      label: "Event Payload Format",
      help: "The server's preference ceiling. Each client negotiates down from it.",
      section: "Security",
      control: .picker(
        options: PayloadCodecID.allCases.map { .init(value: $0.rawValue, label: $0.rawValue) })
    )
  )

  public static let logLevel = Setting<String>(
    "log_level", default: "info",
    presentation: .init(
      label: "Log Level", section: "Debug",
      control: .picker(options: [
        .init(value: "trace", label: "Trace"), .init(value: "debug", label: "Debug"),
        .init(value: "info", label: "Info"), .init(value: "warning", label: "Warning"),
        .init(value: "error", label: "Error"),
      ])))

  // Access control. Failure-only, so a client polling with valid credentials is
  // never throttled.
  /// The master switch for the automatic half of access control: counting failed logins,
  /// blocking an address that crosses the threshold, and throttling an unidentifiable
  /// source. Rate limiting and IP blocking are one feature — blocking is what the rate
  /// limiter does once the threshold is crossed — so they share one toggle.
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
      section: "Security", control: .toggle
    ))
  public static let rateLimitFailureThreshold = Setting<Int>(
    "rate_limit_failures", default: 10,
    presentation: .init(
      label: "Failures Before Block", section: "Security", control: .number(range: 3...1000)))
  public static let rateLimitBlockSeconds = Setting<Int>("rate_limit_block_seconds", default: 900)
  public static let trustLocalNetwork = Setting<Bool>(
    "trust_local_network", default: false,
    presentation: .init(
      label: "Trust My Local Network",
      help:
        "Never rate-limit private-range addresses. Reduces false positives on a LAN-only setup.",
      section: "Security", control: .toggle
    ))
  // ntfy. A first-class delivery route, not a webhook variant: several users run
  // ntfy and no Firebase at all, and the payload is a human-readable notification rather
  // than a JSON body — which is the whole reason `NtfySink` is a separate sink.
  public static let ntfyTopic = Setting<String>(
    "ntfy_topic", default: "",
    presentation: .init(
      label: "ntfy Topic",
      help: "Publish events to an ntfy topic. Leave empty to disable.",
      section: "Notifications", control: .textField
    ))
  public static let ntfyServer = Setting<String>(
    "ntfy_server", default: "https://ntfy.sh",
    presentation: .init(
      label: "ntfy Server",
      help: "Change this if you self-host ntfy.",
      section: "Notifications", control: .textField
    ))
  /// Which events reach the ntfy topic, comma-separated. `*` means everything.
  ///
  /// Defaulting to `*` preserves what every existing install already gets — this sink has
  /// been constructed with the wildcard since it shipped, because nothing ever asked. It
  /// matters more here than for a webhook: ntfy's whole purpose is a readable notification
  /// on a phone, so "everything" means every typing indicator and every FindMy location
  /// update buzzes it.
  public static let ntfyEvents = Setting<String>(
    "ntfy_events", default: "*",
    presentation: .init(
      label: "ntfy Events",
      help: "Which events are published to the topic.",
      section: "Notifications", control: .custom
    ))

  /// Secret: an ntfy access token grants publish rights to the topic.
  public static let ntfyToken = Setting<String>(
    "ntfy_token", default: "", isSecret: true,
    presentation: .init(
      label: "ntfy Access Token",
      help: "Only needed for a protected topic.",
      section: "Notifications", control: .secureField
    ))

  /// Comma-separated addresses or CIDR blocks whose `X-Forwarded-For` header is believed.
  ///
  /// Empty by default, which trusts loopback only — correct for the bundled tunnels, since
  /// ngrok, cloudflared and zrok all run on this machine and connect over 127.0.0.1.
  ///
  /// It matters for the deployment that is NOT bundled: an nginx or Caddy in front of the
  /// server on another host. There every request arrives from one address, so without this
  /// the whole user base shares a single failure counter and ten bad passwords from any one
  /// person locks out everybody — a self-inflicted outage far worse than the brute-force
  /// attempt it was reacting to.
  public static let trustedProxies = Setting<String>(
    "trusted_proxies", default: "",
    presentation: .init(
      label: "Trusted Reverse Proxies",
      help: "Addresses or CIDR blocks allowed to set X-Forwarded-For. "
        + "Leave empty unless the server sits behind your own reverse proxy.",
      section: "Security", control: .textField
    ))

  /// Every setting, for migration and for the coverage checks.
  ///
  /// DERIVED from the declarations rather than listed a second time as strings: `renderable`
  /// is every setting with a presentation, `hidden` is the bookkeeping the UI never shows,
  /// and a key that is in neither list does not exist. Uniqueness is asserted by
  /// `SettingsStoreTests`.
  public static var allKeys: [String] { all.map(\.key) }

  /// Every declared setting, renderable or not.
  public static let all: [AnySetting] = renderable + hidden

  /// Settings with no presentation: read by the server, never shown.
  ///
  /// Several exist only so `LegacyConfigMigration` can read the Electron server's row and
  /// so the key stays reserved; they are read by nothing else. See `Legacy` below.
  static let hidden: [AnySetting] =
    [
      remoteRestartEnabled.erased,
      rateLimitBlockSeconds.erased,
      lastFcmRestart.erased,
      legacyConfigImported.erased,
    ] + Legacy.all

  /// Keys whose values must never appear in a log, an alert, or an exported diagnostic.
  ///
  /// DERIVED from `isSecret` rather than listed a second time. As a literal set it could
  /// miss a setting declared secret later, and the miss was silent in the worst direction:
  /// the value went to the Keychain, but `SettingsScope` let a service read it and nothing
  /// redacted it, because both consult this set rather than the declaration.
  public static let secretKeys: Set<String> = Set(all.filter(\.isSecret).map(\.key))
}

/// The default update feed.
///
/// Declared here rather than imported from BBUpdates so BBSettings does not depend on it —
/// settings sit below everything, and a dependency in that direction would pull the update
/// machinery into every module that reads a setting. `UpdateChecker.defaultFeedURL` carries
/// the same value, and `UpdateFeedTests` asserts they agree.
public enum UpdateFeed {
  public static let defaultURL =
    "https://raw.githubusercontent.com/BlueBubblesApp/bluebubbles-server/master/appcast.xml"
}

// MARK: - The renderable list

extension Settings {

  /// Every setting the generated UI renders, in presentation order.
  ///
  /// Declared here rather than derived by reflection: Swift has no way to enumerate a
  /// type's static members, and a macro to do it would be a lot of machinery to avoid one
  /// list. The `SettingsRegistryTests` coverage check is what keeps this honest — it fails
  /// when a setting declares a presentation and is missing here, which is the mistake this
  /// list invites.
  public static let renderable: [AnySetting] =
    [
      socketPort.erased,
      chatDatabaseReaders.erased,
      serverAddress.erased,
      password.erased,
      connectionMethod.erased,
      bindAddress.erased,
      useCustomCertificate.erased,
      enablePrivateAPI.erased,
      privateAPIHelperPath.erased,
      privateAPIFaceTimeHelperPath.erased,
      enableFaceTimePrivateAPI.erased,
      faceTimeIncomingHandoff.erased,
      faceTimeLinkTTLHours.erased,
      startDelay.erased,
      dbPollInterval.erased,
      autoCaffeinate.erased,
      autoStartMethod.erased,
      startMinimized.erased,
      hideDockIcon.erased,
      dockBadge.erased,
      autoLockMac.erased,
      openFindMyOnStartup.erased,
      landingPagePath.erased,
      checkForUpdates.erased,
      authMode.erased,
      updateFeedURL.erased,
      eventPayloadCodec.erased,
      logLevel.erased,
      rateLimitEnabled.erased,
      rateLimitFailureThreshold.erased,
      trustLocalNetwork.erased,
      trustedProxies.erased,
      ntfyTopic.erased,
      ntfyServer.erased,
      ntfyToken.erased,
      ntfyEvents.erased,
      // Appended rather than listed one by one: `Features.all` is already the single
      // declaration, and transcribing it here is the mistake the coverage check exists to
      // catch. A new flag reaches the settings screen by being declared, and by nothing else.
    ] + Features.all.map(\.setting.erased)

  /// The stored `log_level` as a swift-log level.
  ///
  /// Here rather than at the call site because the picker's option values and the parse have
  /// to agree, and they are two lines apart when they live together.
  public static func logLevel(from raw: String) -> Logger.Level {
    Logger.Level(rawValue: raw.lowercased()) ?? .info
  }

  /// The label the settings screen uses for a key, or the key itself.
  ///
  /// Exists so a permissions list can say "Poll Interval (ms)" instead of `db_poll_interval`.
  /// A storage key is a column name; asking a user to judge whether a plugin should read
  /// `db_poll_interval` is asking them to decode it first.
  ///
  /// Falls back to the key rather than to nothing: a service may legitimately declare a
  /// setting that has no presentation — several are CLI-only — and those still have to
  /// appear in the sentence, since the whole point is that nothing is read undeclared.
  public static func label(forKey key: String) -> String {
    renderable.first { $0.key == key }?.presentation.label ?? key
  }

  /// Renderable settings grouped into their sections, ready for a `Form`.
  public static var renderableSections: [(section: String, settings: [AnySetting])] {
    let visible = renderable.filter { !$0.presentation.isInternal }
    var order: [String] = []
    var grouped: [String: [AnySetting]] = [:]
    for setting in visible {
      let section = setting.presentation.section
      if grouped[section] == nil { order.append(section) }
      grouped[section, default: []].append(setting)
    }
    return order.map { ($0, grouped[$0] ?? []) }
  }
}
