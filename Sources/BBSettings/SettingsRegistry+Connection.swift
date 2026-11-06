//  SettingsRegistry+Connection
//  The settings that decide how clients reach this server: the port, the address, the
//  password, the connection method, TLS and CORS.
//
//  Its own file so a reader changing how the server is reached opens these declarations and
//  not the rest of the registry. The lists that make a setting exist (`Settings.renderable`,
//  `Settings.hidden`) stay in `SettingsRegistry.swift`.

import Foundation

extension Settings {

  // MARK: - Connection

  public static let socketPort = Setting<Int>(
    "socket_port", default: 1234,
    presentation: .init(
      label: "Local Port", section: .connection, control: .number(range: 1...65535))
  )

  /// The address clients use, as PUBLISHED by whichever connection method is running.
  ///
  /// An OUTPUT, not an input, and never rendered as an editable field. The connection
  /// method writes it on every (re)connect, so a typed value would survive only until the
  /// next publish, and a field that saved per keystroke would announce a partial address to
  /// Firebase once per character.
  ///
  /// Where it actually comes from:
  ///   - a tunnel (ngrok, Cloudflare, zrok): the address that tunnel was assigned;
  ///   - Local Network: this Mac's chosen or automatic LAN address plus `socket_port`;
  ///   - Custom URL: echoing back the URL entered on that method's own page.
  ///
  /// Every one of those has its own editable field on its own page. This is the result.
  public static let serverAddress = Setting<String>(
    "server_address", default: "", isConfidential: true,
    presentation: .init(
      label: "Server Address",
      help: "Published by the connection method below. To change it, change that.",
      section: .connection, control: .readOnly)
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
      // rejected: including this row, so this row has the button. Advice naming a control
      // that is not there is worse than no advice.
      section: .connection, control: .secureField, canGenerate: true
    )
  )

  /// Which connection-method service is enabled.
  ///
  /// A service IDENTIFIER, not an enum case. That is what lets a third-party tunnel exist
  /// at all: an enum is compiled into this binary and a plugin cannot add a case to it. It
  /// names a service in the exclusive `reverse-proxy` category, and the registry starts
  /// whichever one matches.
  ///
  /// Rendered by a bespoke view because the options are the INSTALLED services, which is
  /// runtime data: the same reason the network pickers are `.custom`.
  ///
  /// **The default is LAN, and the default is reached before anybody has chosen anything.**
  /// A setting's default is what a server runs on from its first launch until the person
  /// gets to the screen that sets it — so for a connection method it decides what an
  /// unconfigured server does with itself, not merely what a picker is pre-filled with.
  ///
  /// Cloudflare was the default, and the consequence was that a server nobody had
  /// configured yet started a quick tunnel on its own and published a public URL into
  /// `server_address` while its owner was still on the onboarding screens. Nothing leaked
  /// — every route 401s — but "reachable from the internet" is not a state to arrive in by
  /// default, and it is not a state the user can be said to have agreed to.
  ///
  /// LAN is the honest floor: it starts no process, makes no egress, needs no account and
  /// no configuration, and what it publishes is an address on this Mac's own network.
  /// Choosing a tunnel is then something that happens because somebody chose it.
  ///
  /// This is the FRESH-INSTALL default only. An install migrating from the Electron server
  /// keeps whatever it was using, and an unrecognised legacy value still lands on
  /// Cloudflare rather than here — see `Legacy.connectionMethod(forLegacyProxyService:)`,
  /// where the reasoning is the opposite way round: that user already had remote access
  /// working, and quietly dropping them to LAN would take it away.
  public static let connectionMethod = Setting<String>(
    "connection_method", default: "app.bluebubbles.proxy.lan",
    presentation: .init(
      label: "Connection Method",
      help: "How clients reach this server.",
      section: .connection, control: .custom
    )
  )

  /// Whether this server terminates TLS itself.
  ///
  /// Off by default, and that is right for most installs: ngrok, cloudflared, zrok and
  /// Tailscale all terminate TLS before this server, and a second layer inside the tunnel
  /// buys nothing.
  ///
  /// It matters for the deployment that has no tunnel: dynamic DNS, or a port forwarded
  /// straight to this Mac, where the alternative is message content in plaintext across
  /// the internet. Turning it on uses the certificate imported on the Security page, or
  /// generates a self-signed one if there is none.
  ///
  /// Drawn by the HTTP listener's own panel (Configure HTTP Settings on the Connection
  /// page) rather than by the generated form, which is why it is marked internal. It
  /// decides what the LISTENER does, and it sat between "Connection Method" and the
  /// server's address as though it were a third way of reaching the server.
  ///
  /// It stays a CORE setting rather than moving into the HTTP service's own namespace,
  /// which is where a setting only that service reads would belong. Five other services
  /// read it through declared entitlements: `TLSProvisioning` and the four tunnel
  /// methods, each of which needs to know whether the origin it points at speaks TLS,
  /// and a service's own namespace has no cross-service read path, by design.
  public static let useCustomCertificate = Setting<Bool>(
    "use_custom_certificate", default: false,
    presentation: .init(
      label: "Serve over HTTPS",
      help: "Terminate TLS on this Mac. Leave off if a tunnel or reverse proxy already "
        + "does it. Import your certificate on the Security page.",
      section: .connection, control: .toggle,
      isInternal: true
    )
  )

  /// Which browser origins may read this server's responses.
  ///
  /// `*` by default, which is what the reference sends and what every client has always seen,
  /// so this changes nothing until somebody sets it.
  ///
  /// **Narrowing it cannot refuse a non-browser client.** CORS is enforced by browsers and by
  /// nothing else: the app, `curl`, another server, anything behind any tunnel neither sends
  /// `Origin` nor reads `Access-Control-Allow-Origin`. What the default grants is that any page
  /// the user happens to have open may call this server from their browser and READ the
  /// answer — and v1 puts the password in the query string, so it is routinely in the browser's
  /// own history. This is the switch for an operator who serves a web UI of their own and wants
  /// that to be the only page which can.
  ///
  /// A comma-separated list is accepted even though the header carries at most one origin:
  /// several are expressed by echoing the request's own when it matches, which is the only way
  /// the header can say "these three". See `CORSPolicy`.
  ///
  /// Drawn by the HTTP listener's own panel with `bind_address` and `use_custom_certificate`,
  /// which is why it is internal: it configures the LISTENER, and a free-text field about
  /// browsers has no business sitting between "Connection Method" and the server's address.
  /// Read by exactly one service, so it could have lived in the HTTP service's namespace; it
  /// does not, for the reason `bind_address` gives — splitting the panel's three fields across
  /// two storage models costs the panel a second way of reading a field and buys nothing.
  public static let corsAllowedOrigin = Setting<String>(
    "cors_allowed_origin", default: "*",
    presentation: .init(
      label: "Allowed Browser Origins",
      help: "Which web pages may call this server from a browser. `*` allows any. "
        + "Comma-separate several (https://app.example.com, http://localhost:3000). "
        + "Has no effect on the BlueBubbles app or any other non-browser client.",
      section: .connection, control: .textField,
      isInternal: true
    )
  )

  // MARK: - Connection-method credentials
  //
  // There are none here, and that is the point. ngrok's auth token, zrok's account and
  // reserved-share tokens and the rest live in each service's OWN namespace, declared by
  // its manifest: `app.bluebubbles.proxy.zrok.account_token` rather than `zrok_token`. A
  // core registry listing every service's credentials would make "which settings may this
  // service touch?" unanswerable.
}
