//  BuiltInManifests+Core
//  The services that are the server: the HTTP API and event socket, permissions, change
//  detection, search, contacts, the Private API, scheduled messages, the network and sleep
//  watchers, the login item, tool updates and the subscription check.
//
//  Its own file so a reader of what a built-in is allowed to touch opens the manifests the
//  registry always starts, apart from the connection methods and sinks a person switches.
//  The identifiers and the list of every built-in stay in `BuiltInManifests.swift`.

import BBServiceKit
import BBSettings

extension BuiltInManifests {

  // MARK: - Core

  public static let http = ServiceManifest(
    id: ID.http,
    name: "HTTP API",
    summary: "Serves the REST API clients connect to.",
    category: .networking,
    // NOT the socket, which now depends on this; see `BuiltInManifests.socket`. The
    // dependency used to point this way for ordering, because HTTP mounts the socket
    // transport; it does not need the socket SERVICE to have run to do that, since the
    // engine it mounts is built by the composition root either way.
    dependencies: [ID.permissions],
    entitlements: [
      .authenticateRequests,
      // `use_custom_certificate` decides whether the listener terminates TLS, and
      // `server_address` goes in the generated certificate's SAN: a client connecting by
      // the name the server published needs a certificate that matches it.
      .readSettings(keys: [
        Settings.socketPort.key, Settings.bindAddress.key, Settings.useCustomCertificate.key,
        Settings.serverAddress.key,
        // Baked into the router's CORS middleware when it is built, so a change restarts the
        // listener; see `HTTPService.reloadAction`.
        Settings.corsAllowedOrigin.key,
        // Where the installed certificate came from, and when it expires. The renewer acts
        // on these: it regenerates ONLY a self-signed certificate that is genuinely due, and
        // an unknown origin means the user installed it and it must never be replaced.
        Settings.tlsCertificateOrigin.key, Settings.tlsCertificateExpiresAt.key,
      ]),
      // Written when a certificate is generated or imported. Declared as a WRITE so it
      // appears on the permissions list: a service that can rewrite what your server
      // presents as its identity is worth seeing there.
      .writeSettings(keys: [
        Settings.tlsCertificateOrigin.key, Settings.tlsCertificateExpiresAt.key,
      ]),
    ]
  )

  /// The live event channel, carried on the HTTP API's listener.
  ///
  /// It declares a dependency on the HTTP API rather than the other way round, and the
  /// direction is the whole point. The socket has no port of its own: `HTTPService` binds
  /// once and mounts `/socket.io/` on the same router, so the socket is unreachable without
  /// it. Declared this way, switching the HTTP API off takes the socket with it: the
  /// registry does that for any dependency, and switching the SOCKET off leaves the REST
  /// API alone, which is the independence this exists for. Declared the other way, as it
  /// was, turning the socket off would have taken the whole API and every tunnel down.
  public static let socket = ServiceManifest(
    id: ID.socket,
    name: "Socket",
    summary: "Pushes live events to connected clients.",
    details: """
      Runs on the HTTP API's listener rather than a port of its own, so turning it off \
      closes nothing: the address stays up and the REST API is unaffected. What stops is \
      live delivery: events are no longer pushed, and new socket connections are refused \
      rather than accepted and left silent. Clients fall back to asking over the REST API.
      """,
    category: .networking,
    dependencies: [ID.http],
    entitlements: [.receiveEvents(names: []), .authenticateRequests]
  )

  /// Not user-manageable: it reports what macOS has granted, and there is nothing for a
  /// user to switch off. Its screen is the Permissions tab in settings.
  ///
  /// **`entitlements: []` is honest**, for the reason `networkRecovery` gives. It tells the
  /// registry when a permission is granted, which starts other services; what grants that is
  /// `PermissionGrantRouting` in its `Host`, internal to `BlueBubblesServerCore`.
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
    entitlements: [.readMessages, .readSettings(keys: [Settings.dbPollInterval.key])],
    // The one permission that genuinely gates a service. Without it there is no database to
    // watch, so the registry reports that precisely rather than letting the first read fail
    // obscurely.
    permissions: [
      .init(
        .fullDiskAccess, .required,
        purpose: "so it can watch your message database for new and changed messages"
      )
    ]
  )

  /// Builds and maintains the message search index.
  ///
  /// **`isUserManageable: false`, and that is the same call `SleepPrevention` makes.** The
  /// control is `search_index_enabled` — a switch the user meets during onboarding and on the
  /// settings screen, with the explanation attached. A switch of its own on the Integrations
  /// screen would be a SECOND on/off state that could disagree, which is the failure that rule
  /// exists to prevent, and `alwaysOn` is what stops `disabled_services` being one by hand.
  ///
  /// **It is still LISTED there, with that one setting as its control.** It can be switched
  /// on and not running, for want of Full Disk Access above all, and someone in that state
  /// could not find it anywhere: only the log said why. So its page says what state it is in
  /// and offers a retry, and the row on that page IS the setting; see
  /// `IntegrationCatalog.settingControl`.
  ///
  /// Depends on nothing but permissions. It deliberately does NOT depend on the message
  /// watcher: it reads `chat.db` on its own cursor and polls `PRAGMA data_version`, the same
  /// shared-memory read the watcher's backup pass uses, so there is no second poller and no
  /// restart coupling between them.
  public static let messageSearch = ServiceManifest(
    id: ID.messageSearch,
    name: "Message Search",
    summary: "Builds a searchable word list so message text can be found.",
    details: """
      Recent versions of macOS stopped storing the words of a message where other apps can \
      read them, so searching message text finds almost nothing. This reads your history \
      once and records which words appear in which message — a word list, not a copy of your \
      conversations — in a file on this Mac that nothing uploads. Turning the setting off \
      deletes it.
      """,
    category: .messageSource,
    dependencies: [ID.permissions],
    // `.ownStorage` is the one to notice, and this is the first built-in to claim it.
    //
    // The whole feature is "we keep a file derived from your messages", so a permissions
    // list for it that mentioned only reading would be describing the input and hiding the
    // output. `Entitlement.ownStorage` says "Store files of its own" and that is precisely
    // what `search-index.db` is — eleven megabytes on the author's Mac, present until the
    // switch goes off.
    //
    // It matters beyond the wording. These manifests are the worked examples a third-party
    // plugin author copies, and this is the service whose defining characteristic is the
    // file it keeps; a built-in that quietly omits the entitlement for that teaches the
    // omission. See rule 9 in the root `CLAUDE.md`.
    entitlements: [
      .readMessages, .readSettings(keys: [Settings.searchIndexEnabled.key]), .ownStorage,
    ],
    permissions: [
      .init(
        .fullDiskAccess, .required,
        purpose: "so it can read your messages to build the search index"
      )
    ],
    isUserManageable: false
  )

  public static let contacts = ServiceManifest(
    id: ID.contacts,
    name: "Contacts",
    summary: "Indexes your address book so messages show names.",
    category: .contacts,
    dependencies: [ID.permissions],
    entitlements: [.readContacts],
    // Recommended, not required: without it the server runs and shows phone numbers where it
    // would have shown names. Declaring that distinction is the point: a user weighing
    // "should I grant this" needs to know what refusing costs.
    permissions: [
      .init(
        .contacts, .recommended,
        purpose: "so messages show names and photos instead of phone numbers"
      )
    ]
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
        Settings.enablePrivateAPI.key, Settings.privateAPIHelperPath.key,
        Settings.enableFaceTimePrivateAPI.key, Settings.privateAPIFaceTimeHelperPath.key,
        // Carried to the FaceTime helper through the injection environment, so a change
        // re-injects exactly like a dylib path change.
        Settings.faceTimeIdleCameraOff.key,
        // Read by the link sweep this service runs on each FaceTime helper registration.
        // Not one of `faceTimeKeys`, so a change takes effect at the next sweep and
        // re-injects nothing.
        Settings.faceTimeLinkTTLHours.key,
        // Which shape a call-status event goes out in, the reference's `facetime_calling`
        // branch. Read per event; re-injects nothing.
        Settings.faceTimeIncomingHandoff.key,
      ]),
    ],
    // Not a TCC permission and not something the app can prompt for: the user has to
    // disable SIP from Recovery. Declared as required anyway, because the permissions list
    // is where someone finds out what a service will need BEFORE they turn it on, and
    // "reboot into Recovery" is the least welcome thing to discover afterwards.
    permissions: [
      .init(
        .systemIntegrityProtection, .required,
        purpose: "because macOS only allows loading a library inside Messages without it"
      )
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
  /// Not user-manageable: it observes and publishes, and there is nothing to configure or to
  /// switch off. Listing it would put a switch on the Integrations screen whose only effect
  /// would be to stop the server noticing that the network came back.
  public static let networkPath = ServiceManifest(
    id: ID.networkPath,
    name: "Network Awareness",
    summary: "Notices when this Mac's network changes.",
    details: """
      Follows the system's own network path so services that failed while the network was \
      down can be retried when it returns, instead of giving up on a fixed timer. Observes \
      only; it makes no connections of its own.
      """,
    category: .system,
    // NO `.network(hosts:)`, and the absence is the honest declaration: this reads the local
    // routing state and never opens a connection. Claiming egress it does not use would make
    // the permissions list less trustworthy, not more cautious.
    entitlements: [],
    isUserManageable: false
  )

  /// Not user-manageable, for the same reason as the observer it consumes: there is nothing
  /// to configure, and switching it off would only stop failed services being retried.
  ///
  /// **`entitlements: []` is honest, not an omission.** Nothing in the entitlement vocabulary
  /// describes "may restart another service", and the surface is frozen, so inventing a kind
  /// for one built-in is exactly what that freeze forbids. What grants the power is the
  /// `Host` this service is handed: `ServiceRecoveryDriving` is internal to
  /// `BlueBubblesServerCore`, so a third-party plugin cannot name it, let alone be given one.
  /// For a built-in the composition root IS the grant; for a plugin the answer stays no.
  public static let networkRecovery = ServiceManifest(
    id: ID.networkRecovery,
    name: "Network Recovery",
    summary: "Retries services that failed while the network was down.",
    details: """
      When this Mac's network comes back, a service that had already failed is started \
      again rather than waiting for someone to restart the server. Anything still working \
      is left alone.
      """,
    category: .system,
    dependencies: [ID.networkPath],
    entitlements: [],
    isUserManageable: false
  )

  public static let sleepPrevention = ServiceManifest(
    id: ID.sleepPrevention,
    name: "Keep Awake",
    summary: "Stops this Mac sleeping while the server is running.",
    category: .system,
    entitlements: [.readSettings(keys: [Settings.autoCaffeinate.key])],
    isUserManageable: false
  )

  /// Not user-manageable: `auto_start_method` on the General settings page is the switch,
  /// and onboarding asks about it during setup. Listed on the Integrations screen with that
  /// setting as its control, because it can wait on an approval in System Settings that
  /// nothing else on that page mentions; see `IntegrationCatalog.settingControl`.
  public static let launchAtLogin = ServiceManifest(
    id: ID.launchAtLogin,
    name: "Start at Login",
    summary: "Starts this server when you log in.",
    category: .system,
    entitlements: [.readSettings(keys: [Settings.autoStartMethod.key])],
    isUserManageable: false
  )

  /// Not user-manageable: it is the machinery behind the Install and Update buttons on the
  /// pages of whatever declared a program, not a thing to switch on.
  ///
  /// It declares no `network` entitlement of its own, and that is not an oversight. It
  /// reaches a vendor's host only on behalf of the service that DECLARED that tool, and
  /// that service's permission list names the host; see the note on the ngrok manifest.
  /// Restating them here would put the same hosts on a second, invisible list, which is a
  /// worse description of what happens rather than a better one.
  public static let toolUpdates = ServiceManifest(
    id: ID.toolUpdates,
    name: "Program Updates",
    summary: "Checks whether the programs this server uses have newer versions.",
    details: """
      Some connection methods run a program published by someone else: ngrok, \
      cloudflared, zrok. This checks whether newer builds exist and tells you. It never \
      installs one on its own: updating the program that carries your connection is a \
      decision to make while you are at this Mac, not while you are away from it.
      """,
    category: .system,
    entitlements: [
      .readSettings(keys: [Settings.checkForUpdates.key]),
      // It now looks for copies of these programs already on this Mac, and asking a binary
      // its version means RUNNING it. That is the most consequential thing this model does,
      // and the permissions list is the only place a person sees it, so it is declared here
      // rather than left implicit in what `ToolManager` happens to do.
      .spawnProcess,
    ],
    isUserManageable: false
  )

  public static let license = ServiceManifest(
    id: ID.license,
    name: "Subscription",
    summary: "Keeps this server's subscription entitlement current.",
    details: """
      Checks in with the BlueBubbles license service once a day to confirm the subscription \
      is still active. Runs only when a license key has been entered, and affects nothing \
      but the paid features: messaging, notifications and everything the free server does \
      are untouched whether it runs or not.
      """,
    // NOT `.networking`, which is the API SURFACE — the HTTP server and the event socket,
    // the two things a client connects to. This one talks outward on a schedule and serves
    // nobody, which is `toolUpdates`' shape rather than the listener's.
    category: .system,
    symbol: "checkmark.seal",
    version: "1.0.0",
    entitlements: [
      // One host, named. "Uses the network" is not something a person can judge; "talks to
      // our license service and nowhere else" is. It tracks `Settings.licenseEndpoint`'s
      // DEFAULT, which is what a shipped server actually reaches; an operator who points
      // that setting somewhere else has chosen to, and no manifest can enumerate that.
      .network(hosts: ["bluebubbles-license.zlshames.workers.dev"]),
      // The token and its bookkeeping. NOT `license_key`: it is a secret, and a secret is
      // not declarable — `ManifestValidator` refuses a manifest that names one. The service
      // asks `LicenseRuntime` whether a key exists and asks it to exchange one; it never
      // holds the key itself. See `LicenseStore`.
      .readSettings(keys: [
        Settings.licenseToken.key, Settings.licenseLastCheck.key,
        Settings.licenseRevoked.key, Settings.licenseEndpoint.key,
      ]),
      .writeSettings(keys: [
        Settings.licenseToken.key, Settings.licenseLastCheck.key, Settings.licenseRevoked.key,
      ]),
    ],
    // Not user-manageable, and always on (see `alwaysOn`): the license key is the switch.
    // Removing it on the Subscription page is what "off" means here, and a second switch on
    // the Integrations page could only disagree with it.
    isUserManageable: false
  )
}
