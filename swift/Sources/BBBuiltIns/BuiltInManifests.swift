//  BuiltInManifests
//  The built-in services, described in the same model a third-party plugin will use.
//
//  These are the seeded plugins. They ship enabled and are trusted with core entitlements,
//  and that is the ONLY difference — same manifest type, same validator, same entitlement
//  rules, same settings namespace scheme. That is not tidiness: it is the only way to know
//  the model is expressive enough. If the reverse proxies cannot be described here, no
//  third-party plugin will be describable either, and we would find that out after publishing
//  an API rather than before.
//
//  Writing them out has already earned its keep. Three things fell out that the old
//  `ProxyService` enum could not say: that the three tunnels are the same KIND of thing and
//  only one may run at a time; that every one of them needs to run a program, which is
//  exactly the permission a user should be told about; and that zrok's reserved-share fields
//  are meaningless unless a toggle above them is on.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBServiceKit
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

    public static let push = ServiceIdentifier("app.bluebubbles.sink.push")
    public static let webhooks = ServiceIdentifier("app.bluebubbles.sink.webhooks")

    public static let proxyLAN = ServiceIdentifier("app.bluebubbles.proxy.lan")
    public static let proxyDynamicDNS = ServiceIdentifier("app.bluebubbles.proxy.dynamic-dns")
    public static let proxyNgrok = ServiceIdentifier("app.bluebubbles.proxy.ngrok")
    public static let proxyCloudflare = ServiceIdentifier("app.bluebubbles.proxy.cloudflare")
    public static let proxyZrok = ServiceIdentifier("app.bluebubbles.proxy.zrok")
  }

  /// Services that stay running whatever `disabled_services` says.
  ///
  /// The socket is how a connected client is told anything at all, and Permissions only
  /// reports what macOS granted — there is nothing in it to disable.
  ///
  /// The HTTP API is deliberately NOT here, and it is the interesting case: switching it
  /// off stops the server serving, which is a thing an operator may genuinely want and is
  /// also the one switch that can leave a headless install unreachable. It is recoverable
  /// from the CLI — `bluebubbles-server --set disabled_services=` — and the app's own UI
  /// keeps working either way, because it talks to the interfaces in-process rather than
  /// over HTTP. The five reverse proxies declare a dependency on it, so switching it off
  /// takes them down with it rather than leaving an address that resolves to nothing.
  ///
  /// Enforced HERE rather than only in the app's Integrations screen, which is what makes
  /// it true of a settings value written by any other route — the settings API, the CLI's
  /// `--set`, or a hand-edited database.
  public static let alwaysOn: Set<ServiceIdentifier> = [ID.socket, ID.permissions]

  // MARK: - Reverse proxies
  //
  // The category is exclusive, so declaring all five and enabling one replaces the
  // `proxy_service` enum with something the validator can check — and something a plugin
  // can join, which the enum could never be.

  public static let zrok = ServiceManifest(
    id: ID.proxyZrok,
    name: "zrok",
    summary: "Share this server through zrok's open-source tunnel.",
    details: """
      zrok publishes a public address that forwards to this server, so clients can reach \
      it without opening a port on your router. It needs a free zrok account: the account \
      token enables this Mac once, and after that shares can be created on demand.
      """,
    category: .reverseProxy,
    dependencies: [ID.http],
    entitlements: [
      // Every binary tunnel runs a program. Naming it is the point — "runs a program on
      // this Mac" is something a user can weigh, and it is true of ngrok and cloudflared
      // equally.
      .spawnProcess,
      .network(hosts: [
        "api.zrok.io", "zrok.io",
        // Where the zrok agent is downloaded from. See the note on ngrok below.
        "api.github.com", "github.com", "objects.githubusercontent.com",
      ]),
      // Reads the port to forward to, and whether this server terminates TLS — which
      // decides the scheme the share proxies to. NOT the password: a tunnel has no
      // business with it, and there is no entitlement that would hand it over anyway.
      .readSettings(keys: ["socket_port", "use_custom_certificate"]),
      // Every connection method publishes the address clients use. Declared as a WRITE,
      // which is the entitlement the model calls a hijack when a plugin asks for it — and
      // exactly why a person should see it on the list.
      .writeSettings(keys: ["server_address"]),
    ],
    settings: [
      .header("Account"),
      .paragraph(
        "Create a free account at **zrok.io**, then paste your account token below. "
          + "This server runs `zrok enable` with it the first time it starts a "
          + "share, which links this Mac to your account. It only happens once."
      ),
      .field(
        FieldDescriptor(
          key: "account_token",
          label: "Account Token",
          help: "From your zrok account page.",
          kind: .text(placeholder: "zrok token"),
          isSecret: true,
          isRequired: true
        )),

      .divider,
      .header("Share"),
      .paragraph(
        "By default zrok picks a new address every time it starts. A reserved share "
          + "keeps the same address, so clients do not have to be reconfigured."
      ),
      .field(
        FieldDescriptor(
          key: "reserve_tunnel",
          label: "Use a reserved share",
          kind: .toggle()
        )),
      // The conditional fields that motivated `visibleWhen`. Shown unconditionally they
      // invite someone to fill in a value that is then ignored.
      .field(
        FieldDescriptor(
          key: "reserved_name",
          label: "Reserved Name",
          help: "A name to ask zrok for. Leave empty and zrok generates one. Changing "
            + "it releases the old share and reserves a new one, which changes the "
            + "address clients use.",
          kind: .text(placeholder: "my-server"),
          visibleWhen: FieldCondition(field: "reserve_tunnel", equals: "true")
        )),
      .field(
        FieldDescriptor(
          key: "reserved_token",
          label: "Reserved Token",
          help: "Filled in for you once a share has been reserved. Paste one here to "
            + "adopt a share you created yourself with the zrok command line.",
          kind: .text(),
          isSecret: true,
          visibleWhen: FieldCondition(field: "reserve_tunnel", equals: "true")
        )),
      .note(
        "With this off, zrok creates a throwaway share on every start and releases "
          + "it again on the way out."
      ),

      // Folded away by default. Everything in here is for someone running their own
      // zrok, or for diagnosing one that will not come up.
      .collapsedHeader("Advanced"),
      .paragraph(
        "zrok is open source and can be self-hosted. Leave these alone to use "
          + "zrok.io."
      ),
      .field(
        FieldDescriptor(
          key: "api_endpoint",
          label: "API Endpoint",
          help: "The controller for a zrok instance you run yourself. This is passed "
            + "to every zrok command, so your own `~/.zrok` is left untouched.",
          kind: .url
        )),
      .field(
        FieldDescriptor(
          key: "keep_share",
          label: "Keep Reserved Shares",
          help: "A reserved share is deleted from your zrok account when you switch "
            + "reserving off, or when you change its name. Turn this on to leave it "
            + "in place instead — this server just stops using it.",
          kind: .toggle()
        )),
      .field(
        FieldDescriptor(
          key: "verbose_logging",
          label: "Verbose Tunnel Logging",
          help: "Logs everything the zrok agent prints. Worth turning on before asking "
            + "for help with a share that will not connect.",
          kind: .toggle()
        )),
    ],
    tools: [BuiltInTools.zrok]
  )

  public static let ngrok = ServiceManifest(
    id: ID.proxyNgrok,
    name: "ngrok",
    summary: "Share this server through an ngrok tunnel.",
    details: """
      ngrok publishes a public address that forwards to this server. A free account gives \
      you an address that changes each time it restarts; a paid one can keep a fixed \
      domain.
      """,
    category: .reverseProxy,
    dependencies: [ID.http],
    entitlements: [
      .spawnProcess,
      // `bin.equinox.io` is where the agent itself is downloaded from, and it is on
      // this list because `ManifestValidator` requires every host a declared tool
      // reaches to appear here. That is the point of the rule: "runs a program" and
      // "downloads that program from ngrok's distribution host" are two different
      // things to agree to, and a permissions list that mentioned only the first would
      // be describing something other than what happens.
      .network(hosts: [
        "api.ngrok.com", "connect.ngrok-agent.com", "bin.equinox.io",
      ]),
      // `use_custom_certificate` decides whether ngrok is pointed at http or https on
      // loopback. Declared so it appears on the permissions list — a service reading a
      // setting it never announced is what the entitlement model exists to prevent.
      .readSettings(keys: ["socket_port", "use_custom_certificate"]),
      .writeSettings(keys: ["server_address"]),
    ],
    settings: [
      .header("Account"),
      .paragraph(
        "Create a free account at **ngrok.com**, then paste the authtoken from your "
          + "dashboard. Without one ngrok refuses to open a tunnel at all."
      ),
      .field(
        FieldDescriptor(
          key: "auth_token",
          label: "Auth Token",
          help: "From your ngrok dashboard.",
          kind: .text(placeholder: "ngrok authtoken"),
          isSecret: true,
          isRequired: true
        )),
      .note(
        "The token is kept in the Keychain and handed to ngrok through its "
          + "environment, never on its command line — anyone with an account on this "
          + "Mac can read another process's arguments."
      ),

      .divider,
      .header("Tunnel"),
      // No endpoint-type field, and that is deliberate. `ngrok_protocol` existed in the
      // Electron server and offered TCP, which that server then forced back to `http`
      // on every launch — a TCP endpoint publishes a bare host and port, which no
      // BlueBubbles client can use. See `NgrokOptions`.
      .field(
        FieldDescriptor(
          key: "custom_domain",
          label: "Custom Domain",
          help: "A domain reserved on your ngrok dashboard. Paid plans only; leave "
            + "empty for a generated address that changes on every restart.",
          kind: .text(placeholder: "messages.example.com")
        )),
      .field(
        FieldDescriptor(
          key: "region",
          label: "Region",
          help: "Pick the one closest to you.",
          kind: .select(options: [
            // First option is the seeded default and is also ngrok's own, so leaving
            // this alone passes no `--region` at all. See `NgrokOptions.Default`.
            FieldOption(value: "us", label: "United States"),
            FieldOption(value: "eu", label: "Europe"),
            FieldOption(value: "ap", label: "Asia/Pacific"),
            FieldOption(value: "au", label: "Australia"),
            FieldOption(value: "sa", label: "South America"),
            FieldOption(value: "jp", label: "Japan"),
            FieldOption(value: "in", label: "India"),
          ]),
          disabledWhen: FieldCondition(field: "mode", equals: "config"),
          disabledReason:
            "a config.yml owns this setting. Edit it there, or switch Tunnel Type to use one of the other modes."
        )),

      // Folded away by default, which is the point: most people select ngrok, paste a
      // token, and never open this.
      .collapsedHeader("Advanced"),
      .paragraph(
        "These match the ngrok agent's own options. Anything left on its default is "
          + "not passed to ngrok at all, so whatever you have in your own "
          + "`ngrok.yml` stays in charge unless you deliberately change it here — "
          + "with one exception. Request inspection is switched off by default and "
          + "that IS passed to ngrok, because leaving it to the agent's own default "
          + "would mean recording your messages. Turn it back on below if you want "
          + "the inspector."
      ),
      .field(
        FieldDescriptor(
          key: "host_header",
          label: "Host Header",
          help: "What ngrok puts in the `Host:` header it sends this server. "
            + "`rewrite` makes it match your domain. Leave empty unless something "
            + "in front of this server needs it.",
          kind: .text(placeholder: "rewrite")
        )),
      .field(
        FieldDescriptor(
          key: "disable_inspection",
          label: "Disable Request Inspection",
          help: "ngrok's inspector records every request — including message content — "
            + "and keeps it replayable from its dashboard. On by default here, "
            + "because that is a debugging aid for developing an API, and this is a "
            + "message server carrying private conversations. Turn it off only while "
            + "diagnosing a tunnel problem.",
          // ON by default. The inspector is ngrok's own default and is right for
          // someone developing an API against a tunnel; it is wrong for a server whose
          // traffic is somebody's messages, and it costs memory on a busy one.
          kind: .toggle(default: true)
        )),
      .field(
        FieldDescriptor(
          key: "traffic_policy_file",
          label: "Traffic Policy File",
          help: "An ngrok traffic policy file, for rules this page does not cover. "
            + "Needs a recent ngrok agent.",
          kind: .path
        )),
      .field(
        FieldDescriptor(
          key: "verbose_logging",
          label: "Verbose Tunnel Logging",
          help: "Logs everything the ngrok agent prints. Worth turning on before "
            + "asking for help with a tunnel that will not connect.",
          kind: .toggle()
        )),
    ],
    tools: [BuiltInTools.ngrok]
  )

  public static let cloudflare = ServiceManifest(
    id: ID.proxyCloudflare,
    name: "Cloudflare Tunnel",
    summary: "Share this server through a free Cloudflare tunnel.",
    details: """
      Cloudflare's quick tunnels need no account and no configuration. The address \
      changes each time the tunnel restarts, and Cloudflare caps a quick tunnel at 200 \
      requests at once — fine for one household, and the reason someone running a busy \
      server should point this at a tunnel of their own instead.
      """,
    category: .reverseProxy,
    dependencies: [ID.http],
    entitlements: [
      .spawnProcess,
      .network(hosts: [
        "api.trycloudflare.com", "cloudflare.com",
        // A tunnel the user configured themselves does not go through
        // `api.trycloudflare.com` at all — it registers against the edge and is
        // managed through the API. Both belong on the list for the same reason
        // ngrok's distribution host does: the permission screen should describe what
        // actually happens, and it did not.
        "api.cloudflare.com", "argotunnel.com",
        // Where cloudflared is downloaded from. See the note on ngrok above.
        "api.github.com", "github.com", "objects.githubusercontent.com",
      ]),
      // `use_custom_certificate` is read, not written, and it decides whether cloudflared
      // is told to reach this server over http or https. Declared so that appears on the
      // permissions list, because a service reading a setting it never announced is the
      // thing the entitlement model exists to prevent.
      .readSettings(keys: ["socket_port", "use_custom_certificate"]),
      .writeSettings(keys: ["server_address"]),
    ],
    settings: [
      // A header rather than a bare leading note, which would otherwise render as a card
      // called "Configuration" holding one sentence.
      .header("Tunnel"),
      .field(
        FieldDescriptor(
          key: "mode",
          label: "Tunnel Type",
          help: "Quick tunnels need no account. The other two use a tunnel you own.",
          kind: .select(options: [
            // First option is the seeded default — see `seedDefaults` — so `quick` has
            // to stay first. It is also what every existing install is already doing,
            // which is what makes this addition invisible to them.
            FieldOption(value: "quick", label: "Quick Tunnel (no account)"),
            FieldOption(value: "token", label: "My tunnel, using a token"),
            FieldOption(value: "config", label: "My tunnel, using a config file"),
          ])
        )),
      .note(
        "A quick tunnel gets a new address every time it restarts and is capped at "
          + "200 requests at once. A tunnel of your own keeps one address and has "
          + "no such cap."
      ),

      .field(
        FieldDescriptor(
          key: "token",
          label: "Tunnel Token",
          help: "From your tunnel's page in the Cloudflare Zero Trust dashboard. "
            + "It starts with `eyJ`.",
          kind: .text(placeholder: "eyJhIjoi…"),
          // Keychain, not the settings database — and redacted everywhere it might
          // otherwise be printed. It is also kept off cloudflared's command line; see
          // `CloudflareOptions.environment` for why that matters.
          isSecret: true,
          isRequired: true,
          visibleWhen: FieldCondition(field: "mode", equals: "token")
        )),
      .field(
        FieldDescriptor(
          key: "config_file",
          label: "Configuration File",
          help: "The `config.yml` for a tunnel you created yourself.",
          kind: .path,
          isRequired: true,
          visibleWhen: FieldCondition(field: "mode", equals: "config")
        )),
      // Wanted by BOTH named modes and by neither quick one, which is the case a
      // single-valued condition could not describe. See `FieldCondition.orEquals`.
      .field(
        FieldDescriptor(
          key: "hostname",
          label: "Public Hostname",
          help: "The address that routes to this server. cloudflared never prints it "
            + "for a tunnel you configured yourself, so this server cannot work it "
            + "out on its own.",
          kind: .text(placeholder: "messages.example.com"),
          isRequired: true,
          visibleWhen: FieldCondition(field: "mode", equals: "token", orEquals: ["config"])
        )),
      .note(
        "Whichever you use, point its public hostname at **http://localhost** on this "
          + "server's own port — the Connection page shows which one."
      ),

      // Every one of these is folded away by default, which is the whole point: the
      // common case is a user who selects Cloudflare and never opens this section.
      .collapsedHeader("Advanced"),
      .paragraph(
        "These match cloudflared's own options. Anything left on its default is not "
          + "passed to cloudflared at all, so a setting in your own configuration "
          + "file stays in charge unless you deliberately change it here."
      ),
      .note(
        "With a tunnel of your own configured from a `config.yml`, these are locked: "
          + "that file owns them, and this server passes nothing that could "
          + "override it."
      ),
      .field(
        FieldDescriptor(
          key: "protocol",
          label: "Transport",
          help: "cloudflared prefers QUIC, which some routers and ISPs block. "
            + "Switch to HTTP/2 if the tunnel keeps dropping.",
          kind: .select(options: [
            // First option is the seeded default — see `seedDefaults` — so this has to
            // stay `auto`, which is also cloudflared's own default.
            FieldOption(value: "auto", label: "Automatic"),
            FieldOption(value: "quic", label: "QUIC"),
            FieldOption(value: "http2", label: "HTTP/2"),
          ]),
          disabledWhen: FieldCondition(field: "mode", equals: "config"),
          disabledReason:
            "a config.yml owns this setting. Edit it there, or switch Tunnel Type to use one of the other modes."
        )),
      .field(
        FieldDescriptor(
          key: "edge_ip_version",
          label: "Edge IP Version",
          help: "Which address family cloudflared uses to reach Cloudflare. "
            + "IPv6-only networks need this changed.",
          kind: .select(options: [
            FieldOption(value: "4", label: "IPv4"),
            FieldOption(value: "auto", label: "Automatic"),
            FieldOption(value: "6", label: "IPv6"),
          ]),
          disabledWhen: FieldCondition(field: "mode", equals: "config"),
          disabledReason:
            "a config.yml owns this setting. Edit it there, or switch Tunnel Type to use one of the other modes."
        )),
      .field(
        FieldDescriptor(
          key: "region",
          label: "Region",
          help: "Restrict the tunnel to a region's data centres.",
          kind: .select(options: [
            FieldOption(value: "global", label: "Global"),
            FieldOption(value: "us", label: "United States only"),
          ])
        )),
      .field(
        FieldDescriptor(
          key: "verbose_logging",
          label: "Verbose Tunnel Logging",
          help: "Logs everything cloudflared prints. Worth turning on before asking "
            + "for help with a tunnel that will not connect.",
          kind: .toggle()
        )),

    ],
    tools: [BuiltInTools.cloudflared]
  )

  /// Computed, because its options are THIS machine's network interfaces.
  ///
  /// A `static let` cannot know them: a Mac with a VPN, a virtual machine, or both Wi-Fi and
  /// Ethernet has several LAN addresses, and which one a client can actually reach is a fact
  /// about the machine rather than about the service. Re-enumerated on each access so
  /// plugging in a cable adds the option without a restart.
  ///
  /// Safe to compute despite `__version` bookkeeping: `ServiceMigration` keys off
  /// `manifest.version`, which is fixed here, not off deep equality of the manifest.
  public static var lan: ServiceManifest {
    ServiceManifest(
      id: ID.proxyLAN,
      name: "Local Network",
      summary: "Reach this server only from your own network.",
      details: """
        No tunnel at all — clients connect straight to this Mac's address. The simplest and \
        fastest option, and it works only while the client is on the same network.
        """,
      category: .reverseProxy,
      dependencies: [ID.http],
      // No process, no network egress. Worth noticing that this one asks for almost nothing,
      // which is exactly the comparison a permission list is meant to make possible.
      entitlements: [
        .readSettings(keys: ["socket_port"]), .writeSettings(keys: ["server_address"]),
      ],
      settings: [
        .paragraph(
          "Clients connect straight to this Mac. Choose which of its addresses to "
            + "publish — most Macs have one, but a VPN or a virtual machine adds more."
        ),
        .field(
          FieldDescriptor(
            key: "address",
            label: "Address",
            help: "Automatic follows this Mac's primary interface. Pick a specific "
              + "address if clients can only reach one of them. If a pinned address "
              + "disappears, the automatic one is published instead.",
            kind: .select(options: lanAddressOptions())
          )),
      ]
    )
  }

  /// Automatic, then one option per IPv4 interface.
  ///
  /// The automatic entry names the address it currently resolves to, because "Automatic" on
  /// its own does not answer the question the user opened this field to ask — which address
  /// their clients are going to be handed.
  static func lanAddressOptions() -> [FieldOption] {
    let automatic = SystemInfo.primaryIPv4()
    var options = [
      FieldOption(
        value: "",
        label: automatic.map { "Automatic (\($0))" } ?? "Automatic"
      )
    ]
    // Interface name alongside the address: on a Mac with a VPN up, two private addresses
    // look equally plausible and `utun3` versus `en0` is the thing that distinguishes them.
    for interface in SystemInfo.interfaces(.ipv4) {
      options.append(
        FieldOption(
          value: interface.address,
          label: "\(interface.address) (\(interface.name))"
        ))
    }
    return options
  }

  /// Named "Custom URL" and identified `…proxy.dynamic-dns`.
  ///
  /// The NAME changed and the ID did not, deliberately: the identifier is the key every
  /// stored setting for this method hangs off (`app.bluebubbles.proxy.dynamic-dns.address`)
  /// and the value `connection_method` holds, so renaming it would orphan the address of
  /// anyone already using it and silently reset them to no connection method at all.
  ///
  /// "Dynamic DNS" described one way of keeping the record current rather than what this
  /// option does, which is publish a URL you supply. Dynamic DNS is a way to make that URL
  /// keep working; it is not a requirement, and a static record or a reverse proxy you run
  /// yourself fits here just as well.
  public static let dynamicDNS = ServiceManifest(
    id: ID.proxyDynamicDNS,
    name: "Custom URL",
    summary: "Publish an address you manage yourself.",
    details: """
      For people running their own DNS, port forwarding or reverse proxy. This server \
      publishes the URL you enter and does nothing else — keeping it pointing at your \
      network is up to you, whether that is a static record or a dynamic DNS client.
      """,
    category: .reverseProxy,
    dependencies: [ID.http],
    entitlements: [
      .readSettings(keys: ["socket_port"]), .writeSettings(keys: ["server_address"]),
    ],
    settings: [
      .field(
        FieldDescriptor(
          key: "address",
          label: "Address",
          help: "The full URL clients should use, including the port.",
          kind: .url,
          isRequired: true
        ))
    ]
  )

  // MARK: - Event sinks
  //
  // The contrast that makes exclusivity worth modelling: these are all expected to run at
  // once, so the category is additive and enabling one does not disable another.

  public static let webhooks = ServiceManifest(
    id: ID.webhooks,
    name: "Webhooks",
    summary: "POST server events to your own endpoints.",
    details: "Every event this server produces can be sent to a URL you control.",
    category: .eventSink,
    entitlements: [
      .receiveEvents(names: []),
      .network(hosts: ["*"]),
      // The ntfy sink's configuration. `ntfy_token` is absent because it is a secret and no
      // entitlement may name one; `WebhookDeliveryService` adds it to its watch list.
      .readSettings(keys: ["ntfy_topic", "ntfy_server", "ntfy_events"]),
    ]
  )

  public static let push = ServiceManifest(
    id: ID.push,
    name: "Push Notifications",
    summary: "Deliver notifications while the client app is closed.",
    details: """
      Uses Firebase Cloud Messaging. Entirely optional — without it clients still receive \
      everything while they are open.
      """,
    category: .eventSink,
    entitlements: [
      .receiveEvents(names: []),
      .network(hosts: [
        "fcm.googleapis.com", "firestore.googleapis.com",
        "oauth2.googleapis.com", "firebaserules.googleapis.com",
      ]),
      // `remote_restart_enabled` and `last_fcm_restart` are read too, and deliberately
      // not declared: neither has a presentation, so the permissions sentence could only
      // name them by their column names. `PushDeliveryService` watches the first itself;
      // the second is its own bookkeeping write.
      .readSettings(keys: ["server_address"]),
    ]
  )

  // MARK: - Core

  public static let http = ServiceManifest(
    id: ID.http,
    name: "HTTP API",
    summary: "Serves the REST API clients connect to.",
    category: .networking,
    dependencies: [ID.permissions, ID.socket],
    entitlements: [
      .authenticateRequests,
      // `use_custom_certificate` decides whether the listener terminates TLS.
      .readSettings(keys: ["socket_port", "bind_address", "use_custom_certificate"]),
    ]
  )

  public static let socket = ServiceManifest(
    id: ID.socket,
    name: "Socket",
    summary: "Pushes live events to connected clients.",
    category: .networking,
    entitlements: [.receiveEvents(names: []), .authenticateRequests]
  )

  /// Not user-manageable: it reports what macOS has granted, and there is nothing for a
  /// user to switch off. Its screen is the Permissions tab in settings.
  public static let permissions = ServiceManifest(
    id: ID.permissions,
    name: "Permissions",
    summary: "Tracks the macOS permissions this server needs.",
    category: .system,
    isUserManageable: false
  )

  public static let changeDetection = ServiceManifest(
    id: ID.changeDetection,
    name: "Message Watcher",
    summary: "Watches the message database and turns new rows into events.",
    category: .messageSource,
    dependencies: [ID.permissions],
    entitlements: [.readMessages, .readSettings(keys: ["db_poll_interval"])]
  )

  public static let contacts = ServiceManifest(
    id: ID.contacts,
    name: "Contacts",
    summary: "Indexes your address book so messages show names.",
    category: .contacts,
    dependencies: [ID.permissions],
    entitlements: [.readContacts]
  )

  public static let privateAPI = ServiceManifest(
    id: ID.privateAPI,
    name: "Private API",
    summary: "Reactions, editing, typing indicators and group management.",
    details: """
      Loads a small library inside Messages, which macOS permits only with System \
      Integrity Protection disabled.
      """,
    category: .messaging,
    dependencies: [ID.permissions],
    entitlements: [
      .sendMessages, .readMessages, .spawnProcess,
      // Which helpers to inject and from where. A change to any of them re-injects.
      .readSettings(keys: [
        "enable_private_api", "private_api_helper_path",
        "enable_ft_private_api", "private_api_facetime_helper_path",
      ]),
    ]
  )

  public static let scheduledMessages = ServiceManifest(
    id: ID.scheduledMessages,
    name: "Scheduled Messages",
    summary: "Sends messages at a time you choose.",
    category: .messaging,
    // Sends through the same path a client does, so the send path has to be up first.
    // Declared here rather than as a separate static: the manifest is the only place
    // dependencies are stated now.
    dependencies: [ID.privateAPI],
    entitlements: [.sendMessages]
  )

  /// Not user-manageable: `auto_caffeinate` on the General settings page is the switch.
  /// A second one here could disagree with it, and did.
  public static let sleepPrevention = ServiceManifest(
    id: ID.sleepPrevention,
    name: "Keep Awake",
    summary: "Stops this Mac sleeping while the server is running.",
    category: .system,
    entitlements: [.readSettings(keys: ["auto_caffeinate"])],
    isUserManageable: false
  )

  /// Not user-manageable: `auto_start_method` on the General settings page is the switch,
  /// and onboarding asks about it during setup.
  public static let launchAtLogin = ServiceManifest(
    id: ID.launchAtLogin,
    name: "Start at Login",
    summary: "Starts this server when you log in.",
    category: .system,
    entitlements: [.readSettings(keys: ["auto_start_method"])],
    isUserManageable: false
  )

  /// Not user-manageable: it is the machinery behind the Install and Update buttons on the
  /// pages of whatever declared a program, not a thing to switch on.
  ///
  /// It declares no `network` entitlement of its own, and that is not an oversight. It
  /// reaches a vendor's host only on behalf of the service that DECLARED that tool, and
  /// that service's permission list names the host — see the note on the ngrok manifest.
  /// Restating them here would put the same hosts on a second, invisible list, which is a
  /// worse description of what happens rather than a better one.
  public static let toolUpdates = ServiceManifest(
    id: ID.toolUpdates,
    name: "Program Updates",
    summary: "Checks whether the programs this server uses have newer versions.",
    details: """
      Some connection methods run a program published by someone else — ngrok, \
      cloudflared, zrok. This checks whether newer builds exist and tells you. It never \
      installs one on its own: updating the program that carries your connection is a \
      decision to make while you are at this Mac, not while you are away from it.
      """,
    category: .system,
    entitlements: [.readSettings(keys: ["check_for_updates"])],
    isUserManageable: false
  )

  /// Every built-in, for validation and for the UI.
  public static let all: [ServiceManifest] = [
    http, socket, permissions, changeDetection, contacts, privateAPI,
    scheduledMessages, sleepPrevention, launchAtLogin, toolUpdates,
    push, webhooks,
    lan, dynamicDNS, ngrok, cloudflare, zrok,
  ]
}
