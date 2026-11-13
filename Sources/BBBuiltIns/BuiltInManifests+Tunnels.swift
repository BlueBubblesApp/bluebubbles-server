//  BuiltInManifests+Tunnels
//  The connection methods that run a program: zrok, ngrok, Cloudflare and Tailscale, and the
//  entitlements every binary tunnel declares.
//
//  Its own file so a reader comparing what the tunnels ask for opens the four that spawn a
//  process and reach a host, without the methods that only publish an address
//  (`BuiltInManifests+Publishing.swift`). The identifiers and the list of every built-in stay
//  in `BuiltInManifests.swift`.

import BBServiceKit
import BBSettings

extension BuiltInManifests {

  // MARK: - Reverse proxies
  //
  // The category is exclusive, so declaring all six and enabling one gives the validator
  // something to check, and gives a plugin something to join, which an enum could never
  // be.

  // MARK: - What every connection method declares

  /// The entitlements a binary tunnel declares. Every binary tunnel runs a program: naming
  /// it is the point: "runs a program on this Mac" is something a user can weigh, and it is
  /// true of ngrok and cloudflared equally. It reaches the hosts named per method, with the
  /// reason for each at the call site. It reads the port to forward to, and whether this
  /// server terminates TLS (which decides the scheme the tunnel proxies to) and NOT the
  /// password: a tunnel has no business with it, and there is no entitlement that would
  /// hand it over anyway. And it publishes the address clients use, declared as a WRITE,
  /// which is the entitlement the model calls a hijack when a plugin asks for it, exactly
  /// why a person should see it on the list.
  ///
  /// One function rather than four copies, so a key a tunnel starts reading is declared
  /// once and the validator cannot catch three of them out.
  static func tunnelEntitlements(hosts: Set<String>) -> [Entitlement] {
    [
      .spawnProcess,
      .network(hosts: hosts),
      .readSettings(keys: [
        Settings.connectionMethod.key, Settings.socketPort.key, Settings.useCustomCertificate.key,
      ]),
      .writeSettings(keys: [Settings.serverAddress.key]),
    ]
  }

  /// What a method with no process and no network egress declares: Local Network and
  /// Custom URL. Worth noticing how little it is, which is exactly the comparison a
  /// permission list is meant to make possible.
  static let publishingEntitlements: [Entitlement] = [
    .readSettings(keys: [Settings.connectionMethod.key, Settings.socketPort.key]),
    .writeSettings(keys: [Settings.serverAddress.key]),
  ]

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
    symbol: "bolt.horizontal",
    dependencies: [ID.http],
    entitlements: tunnelEntitlements(hosts: [
      "api.zrok.io", "zrok.io",
      // Where the zrok agent is downloaded from. See the note on ngrok below.
      "api.github.com", "github.com", "objects.githubusercontent.com",
    ]),
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
          help: "A name to ask zrok for: 4 to 32 characters, lowercase letters and "
            + "digits only. Leave empty and zrok generates one. Changing it releases the "
            + "old share and reserves a new one, which changes the address clients use.",
          // NOT "my-server". zrok refuses a hyphen, so the placeholder was an example of
          // a name it would reject, in the field whose rule it was demonstrating.
          kind: .text(placeholder: "myserver"),
          isConfidential: true,
          visibleWhen: FieldCondition(field: "reserve_tunnel", equals: "true"),
          // zrok's own rule, checked here so it is answered while the field is on screen.
          // Empty is allowed and means "zrok picks one"; see `ZrokMethod`.
          validation: FieldValidation(
            pattern: "[a-z0-9]{4,32}",
            message: "zrok names must be 4 to 32 characters, lowercase letters and digits "
              + "only: no capitals, spaces, hyphens or underscores."
          )
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
            + "in place instead; this server just stops using it.",
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
    tools: [BuiltInTools.zrok],
    // Opens a session with somebody else's infrastructure, so "Connected"
    // is a true thing to say about it. See the field.
    connectsToExternalService: true
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
    symbol: "point.3.connected.trianglepath.dotted",
    dependencies: [ID.http],
    // `bin.equinox.io` is where the agent itself is downloaded from, and it is on this
    // list because `ManifestValidator` requires every host a declared tool reaches to
    // appear here. That is the point of the rule: "runs a program" and "downloads that
    // program from ngrok's distribution host" are two different things to agree to, and a
    // permissions list that mentioned only the first would be describing something other
    // than what happens.
    entitlements: tunnelEntitlements(hosts: [
      "api.ngrok.com", "connect.ngrok-agent.com", "bin.equinox.io",
    ]),
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
          + "environment, never on its command line; anyone with an account on this "
          + "Mac can read another process's arguments."
      ),

      .divider,
      .header("Tunnel"),
      // No endpoint-type field, and that is deliberate. `ngrok_protocol` existed in the
      // Electron server and offered TCP, which that server then forced back to `http`
      // on every launch: a TCP endpoint publishes a bare host and port, which no
      // BlueBubbles client can use. See `NgrokOptions`.
      .field(
        FieldDescriptor(
          key: "custom_domain",
          label: "Custom Domain",
          help: "A domain reserved on your ngrok dashboard. Paid plans only; leave "
            + "empty for a generated address that changes on every restart.",
          kind: .text(placeholder: "messages.example.com"),
          isConfidential: true
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
          + "`ngrok.yml` stays in charge unless you deliberately change it here; "
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
          help: "ngrok's inspector records every request (including message content) "
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
    tools: [BuiltInTools.ngrok],
    // Opens a session with somebody else's infrastructure, so "Connected"
    // is a true thing to say about it. See the field.
    connectsToExternalService: true
  )

  public static let cloudflare = ServiceManifest(
    id: ID.proxyCloudflare,
    name: "Cloudflare Tunnel",
    summary: "Share this server through a free Cloudflare tunnel.",
    details: """
      Cloudflare's quick tunnels need no account and no configuration. The address \
      changes each time the tunnel restarts, and Cloudflare caps a quick tunnel at 200 \
      requests at once: fine for one household, and the reason someone running a busy \
      server should point this at a tunnel of their own instead.
      """,
    category: .reverseProxy,
    symbol: "cloud",
    dependencies: [ID.http],
    entitlements: tunnelEntitlements(hosts: [
      "api.trycloudflare.com", "cloudflare.com",
      // A tunnel the user configured themselves does not go through
      // `api.trycloudflare.com` at all: it registers against the edge and is
      // managed through the API. Both belong on the list for the same reason
      // ngrok's distribution host does: the permission screen should describe what
      // actually happens, and it did not.
      "api.cloudflare.com", "argotunnel.com",
      // Where cloudflared is downloaded from. See the note on ngrok above.
      "api.github.com", "github.com", "objects.githubusercontent.com",
    ]),
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
            // First option is the seeded default; see `seedDefaults`, so `quick` has
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
          // Keychain, not the settings database, and redacted everywhere it might
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
          isConfidential: true,
          isRequired: true,
          visibleWhen: FieldCondition(field: "mode", equals: "token", orEquals: ["config"])
        )),
      .note(
        "Whichever you use, point its public hostname at **http://localhost** on this "
          + "server's own port; the Connection page shows which one."
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
            // First option is the seeded default; see `seedDefaults`, so this has to
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
    tools: [BuiltInTools.cloudflared],
    // Opens a session with somebody else's infrastructure, so "Connected"
    // is a true thing to say about it. See the field.
    connectsToExternalService: true
  )

  /// Tailscale, as this server's own node on the user's tailnet.
  ///
  /// The one connection method whose setup can be PENDING ON A PERSON at three separate
  /// points: signing in, enabling HTTPS certificates, enabling Funnel, so the form leads
  /// with the two ways to sign in and the service reports each of the three through a
  /// notification carrying the link, rather than failing. Also the only one that offers a
  /// private address: tailnet-only is the default because it needs nothing enabled on the
  /// tailnet beyond certificates, and because a person who chose Tailscale usually has it
  /// on their phone already.
  public static let tailscale = ServiceManifest(
    id: ID.proxyTailscale,
    name: "Tailscale",
    summary: "Reach this server over your tailnet, or publish it with Funnel.",
    details: """
      This Mac joins your Tailscale network as its own device and serves this server at a \
      `.ts.net` address with a real certificate. By default only devices signed in to your \
      tailnet can reach it; Tailscale Funnel can open it to the internet instead. Needs a \
      free Tailscale account, and the Tailscale app on each phone or computer that connects \
      unless Funnel is on. The Tailscale daemon is downloaded on first use from MacPorts' \
      package server; MacPorts itself does not need to be installed.
      """,
    category: .reverseProxy,
    symbol: "lock.shield",
    dependencies: [ID.http],
    entitlements: tunnelEntitlements(hosts: [
      // Signing in, the coordination server, and the DERP relays that carry traffic
      // when a direct path cannot be found. What a host list CANNOT name is the direct
      // path itself: a tailnet peer is reached by its own address once one is found,
      // and this list is what the permissions screen shows, not what is enforced.
      "login.tailscale.com", "controlplane.tailscale.com", "*.tailscale.com",
      // Where the certificate for the address is issued.
      "acme-v02.api.letsencrypt.org",
      // Where the daemon and its signature are downloaded from. See the note on ngrok
      // above.
      "packages.macports.org",
    ]),
    settings: [
      .header("Account"),
      .paragraph(
        "Create a free account at **tailscale.com**. This Mac joins your tailnet as a "
          + "device of its own (separate from any Tailscale app you already run here) and "
          + "signs in one of two ways: paste an auth key below, or leave it empty and open "
          + "the sign-in link this server shows in Notifications the first time it starts."
      ),
      .field(
        FieldDescriptor(
          key: "auth_key",
          label: "Auth Key",
          help: "Optional. Generate one under Settings › Keys in the Tailscale admin "
            + "console. A reusable, pre-approved key lets this Mac sign in again on its "
            + "own if its key ever expires. Used only to sign in, and kept in the Keychain.",
          kind: .text(placeholder: "tskey-auth-…"),
          isSecret: true
        )),
      .field(
        FieldDescriptor(
          key: "hostname",
          label: "Machine Name",
          help: "The name this Mac takes on your tailnet, which becomes the first part of "
            + "the address clients use. Letters, digits and hyphens.",
          kind: .text(placeholder: "bluebubbles"),
          isConfidential: true
        )),

      .divider,
      .header("Reach"),
      .field(
        FieldDescriptor(
          key: "exposure",
          label: "Who Can Connect",
          help: "Tailnet only: every phone or computer running the BlueBubbles client "
            + "also runs the Tailscale app, signed in to the same tailnet; nothing is "
            + "exposed to the internet. Funnel: anyone with the address, through "
            + "Tailscale's relays; it has to be enabled once for your tailnet, and this "
            + "server shows the link if it is not.",
          kind: .select(options: [
            FieldOption(value: "tailnet", label: "Only devices on my tailnet"),
            FieldOption(value: "funnel", label: "Anyone, through Tailscale Funnel"),
          ])
        )),
      .field(
        FieldDescriptor(
          key: "https_port",
          label: "Port",
          help: "The port on the tailnet address. 443 keeps the address short; the other "
            + "two are the only others Funnel permits.",
          kind: .select(options: [
            FieldOption(value: "443", label: "443"),
            FieldOption(value: "8443", label: "8443"),
            FieldOption(value: "10000", label: "10000"),
          ])
        )),
      .note(
        "Tailscale issues a certificate for the address, so HTTPS certificates must be "
          + "enabled for your tailnet. This server shows the link if they are not."
      ),

      // Folded away by default: a self-hosted control server and the log switch are for
      // people who know they want them.
      .collapsedHeader("Advanced"),
      .field(
        FieldDescriptor(
          key: "control_url",
          label: "Control Server",
          help: "For a Headscale or other self-hosted control server. Leave empty for "
            + "Tailscale's own. Funnel is not available on a self-hosted control server.",
          kind: .url
        )),
      .field(
        FieldDescriptor(
          key: "send_logs",
          label: "Send Diagnostic Logs to Tailscale",
          help: "Off runs the daemon with `--no-logs-no-support`, so nothing about this Mac "
            + "is uploaded to Tailscale's log service. Turn on only if Tailscale support "
            + "asks for it.",
          kind: .toggle()
        )),
      .field(
        FieldDescriptor(
          key: "verbose_logging",
          label: "Verbose Tunnel Logging",
          help: "Logs everything the Tailscale daemon prints, which is a great deal. Worth "
            + "turning on before asking for help with a node that will not connect.",
          kind: .toggle()
        )),
    ],
    tools: [BuiltInTools.tailscale],
    // Opens a session with somebody else's infrastructure, so "Connected"
    // is a true thing to say about it. See the field.
    connectsToExternalService: true
  )
}
