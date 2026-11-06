//  SettingsRegistry+UpdatesAndSetup
//  Updates, and the bookkeeping the server keeps about itself: the bind address, the
//  migration steps, onboarding, where the TLS material came from, and the remote restart.
//
//  Its own file so the rows a person never sees are read apart from the ones they do. The
//  lists that make a setting exist (`Settings.renderable`, `Settings.hidden`) stay in
//  `SettingsRegistry.swift`.

import Foundation

extension Settings {

  // MARK: - Updates and setup

  /// Off by default. An automatic check reaches out to the network on a schedule the user
  /// did not ask for; onboarding offers it, and the menu item works regardless.
  public static let checkForUpdates = Setting<Bool>(
    "check_for_updates", default: false,
    presentation: .init(
      label: "Check for Updates",
      help: "Looks for a new release once a day. You can always check by hand from the "
        + "BlueBubbles menu.",
      section: .updates,
      control: .toggle
    ))

  /// Whether a new release installs without anyone at the Mac.
  ///
  /// Off by default. On, Sparkle downloads a release in the background once the daily
  /// check finds one and installs it the next time the app relaunches; `POST
  /// /server/update/install` installs and relaunches at once. A server left running in a
  /// closet wants this; a person who reads release notes first does not. The Electron server
  /// had the same key (its `autoUpdater.autoInstallOnAppQuit`), so an upgraded install
  /// keeps its answer. Read by `SparkleUpdater` alone.
  public static let autoInstallUpdates = Setting<Bool>(
    "auto_install_updates", default: false,
    presentation: .init(
      label: "Install Updates Automatically",
      // NOT "Needs Check for Updates" any more: `requires` says that structurally, and the
      // row greys out and names the switch rather than describing a rule the person then
      // has to apply themselves.
      help: "Downloads a new release in the background and installs it at the hour below, "
        + "relaunching BlueBubbles.",
      section: .updates,
      control: .toggle,
      // Nothing installs automatically without the daily check that finds the release:
      // `SparkleUpdater` maps this to `automaticallyDownloadsUpdates`, which never fires
      // while `automaticallyChecksForUpdates` is off. The manual menu item is unaffected,
      // which is why `checkForUpdates` itself hangs off nothing.
      requires: checkForUpdates.key
    ))

  /// Whether pre-releases are offered.
  ///
  /// Off by default. On, the update check and Sparkle both read the `beta` channel of the
  /// same feed as well as the default one, so a beta is offered exactly as a release is:
  /// same signature check, same notes, same install paths. Turning it off does not roll
  /// back: an installed beta stays until the next release outranks it. This is what the
  /// read-only feed URL is FOR; a person who wants betas flips this rather than editing a
  /// URL. Read per check by `UpdateHandlers` and `SparkleUpdater`.
  public static let receiveBetaUpdates = Setting<Bool>(
    "receive_beta_updates", default: false,
    presentation: .init(
      label: "Receive Beta Releases",
      help: "Offers pre-release builds as updates. They are signed and installed exactly "
        + "like releases, and may have rough edges.",
      section: .updates,
      control: .toggle
    ))

  /// The version the app last ran as. Bookkeeping, never shown.
  ///
  /// Written by the app at every start and read once, before the write, so a start on a
  /// different version can say "Updated to X" with a link to its notes. Empty on a fresh
  /// install, which says nothing. See `UpdatesModel.noteVersionChange`.
  public static let lastRunVersion = Setting<String>("last_run_version", default: "")

  /// The hour of the day an automatically downloaded update relaunches the app.
  ///
  /// Local time on the Mac, 0 to 23. Sparkle's own behaviour is to install on quit, and a
  /// server that runs all day never quits; this is what makes the toggle above mean what
  /// it says. `InstallWindow` (in the app) does the arithmetic and holds the relaunch while
  /// a scheduled message is about to go out. Read by `SparkleUpdater` alone.
  public static let autoInstallHour = Setting<Int>(
    "auto_install_hour", default: 3,
    presentation: .init(
      label: "Install Updates At",
      help: "The hour (0 to 23, this Mac's time zone) when a downloaded update is installed "
        + "and BlueBubbles relaunches. The relaunch waits if a scheduled message is due "
        + "within fifteen minutes.",
      section: .updates,
      control: .number(range: 0...23),
      // The hour hangs off the AUTOMATIC install, not off the check: it is the answer to
      // "when does the thing you already agreed to happen", and it is meaningless if
      // nothing installs unattended. That makes this the one two-link chain in the
      // registry, and the reason `Settings.blockingRequirement` names the OUTERMOST switch
      // that is off rather than the nearest: with checks off, telling somebody to turn on
      // Install Updates Automatically points them at a row that is itself greyed out.
      requires: autoInstallUpdates.key
    ))
  /// Which network interface the HTTP API and socket listen on.
  ///
  /// `0.0.0.0` (every interface) is the default and matches the reference, which
  /// binds it unconditionally. The setting exists because that is not always what a user
  /// wants:
  ///
  /// - **With a tunnel, `127.0.0.1` is strictly better.** cloudflared, ngrok and zrok all
  ///   run on THIS machine and connect to the server locally, so binding wider exposes the
  ///   API to the whole LAN for no benefit at all. That is the one configuration where a
  ///   narrower bind costs nothing and removes an entire attack surface.
  /// - A Mac with several networks (a VPN, a lab VLAN, a virtualisation bridge) may want
  ///   to serve on exactly one of them.
  ///
  /// Stored as the address rather than an interface name because that is what `bind(2)`
  /// takes, and because an interface's address is the thing a user recognises. The UI
  /// offers the live list; `.custom` because the options depend on this machine and the
  /// generated settings screen only renders static ones.
  ///
  /// Drawn by the HTTP listener's own panel, with `use_custom_certificate`; see there for
  /// why both moved off the generated page. This one has exactly one reader, so it COULD
  /// have moved into the HTTP service's namespace; it did not, because splitting the pair
  /// across two storage models would buy nothing and cost the shared panel a second way of
  /// reading a field.
  public static let bindAddress = Setting<String>(
    "bind_address", default: "0.0.0.0",
    presentation: .init(
      label: "Listen On",
      help: "Which network this server accepts connections from. "
        + "If you use a tunnel, Loopback is the safest choice.",
      section: .connection, control: .custom,
      isInternal: true
    )
  )

  // `lan_address` lives in the LAN connection method's own namespace
  // (`app.bluebubbles.proxy.lan.address`), declared by its manifest, like every other
  // service's configuration.

  public static let lastFcmRestart = Setting<Int>("last_fcm_restart", default: 0)

  /// Whether the Electron server's `config.db` has already been imported.
  ///
  /// The import writes unconditionally: it does not compare against defaults, so without
  /// this marker it would re-run on every launch and overwrite anything the user had since
  /// changed in the Swift app with the value the old server had. One-way and one-time by
  /// design: the Electron database is the source only until the Swift server owns the
  /// settings, which is the moment the first import finishes.
  ///
  /// No `presentation`: this is bookkeeping, not something to show a user.
  /// Services the user has switched off, as a comma-separated list of identifiers.
  ///
  /// A deny-list rather than an allow-list, so a service that ships in a later version is
  /// enabled by default, which is what "seeded plugin" means. An allow-list would leave
  /// every new built-in silently off for existing installs.
  public static let disabledServicesKey = "disabled_services"

  public static let legacyConfigImported = Setting<Bool>(
    "legacy_config_imported", default: false
  )

  // MARK: Migration state
  //
  // One row per step.
  //
  // A multi-step migration needs to record which steps finished, or a run that fails
  // half-way has nowhere to say so and the next attempt has to redo everything, and
  // redoing the settings import is not harmless, because it writes every key it finds with
  // no comparison and so reverts anything the user changed in between.
  //
  // Separate rows rather than one JSON blob for two reasons: a blob cannot be written
  // inside the same `SettingsStore.write` batch as the import it is recording (which is what
  // makes the pair atomic), and a partial write of a blob loses the other steps with it.
  //
  // `legacy_config_imported` stays declared and is read as the seed for the settings step,
  // so the installs that already migrated under the old scheme are not offered it again.
  // Values are `MigrationStepState` raw values.

  public static let migrationSettingsState = Setting<String>(
    "migration_settings_state", default: ""
  )
  public static let migrationPushState = Setting<String>(
    "migration_push_state", default: ""
  )
  public static let migrationCertificatesState = Setting<String>(
    "migration_certificates_state", default: ""
  )
  public static let migrationPlaintextSecretsState = Setting<String>(
    "migration_plaintext_secrets_state", default: ""
  )
  public static let migrationSavedRecordsState = Setting<String>(
    "migration_saved_records_state", default: ""
  )

  /// Whether the setup walkthrough has been finished on THIS server.
  ///
  /// **In `app.db` rather than `UserDefaults`, because it is a fact about the server and
  /// not about the Mac.** It used to live in defaults, and the split showed: `app.db` is
  /// the unit a person backs up, restores and copies, so clearing it left a server with no
  /// settings and an app certain setup was done — which is a walkthrough that never appears
  /// over a server that has never been configured. Adopting an Electron install on a Mac
  /// where this app had run before had the same shape.
  ///
  /// It is also what `BB_SUPPORT_DIRECTORY` could not isolate. That override redirects the
  /// files and hashes the Keychain service precisely so a redirected run cannot touch the
  /// real installation; `UserDefaults` is keyed by bundle id and was reached by both.
  ///
  /// The permission-skip keys stay in defaults deliberately: a TCC grant belongs to the app
  /// bundle on one Mac, not to a particular server's database.
  public static let onboardingComplete = Setting<Bool>(
    "onboarding_complete", default: false
  )

  /// The walkthrough's answers, as the JSON `OnboardingSelections` encodes itself to.
  ///
  /// One opaque string rather than a setting per answer: the shape belongs to the app and
  /// changes with it, and five keys in this registry would make a UI decision part of the
  /// server's configuration vocabulary. See `onboardingComplete` for why it is here at all.
  public static let onboardingSelections = Setting<String>(
    "onboarding_selections", default: ""
  )

  /// How much of Home is shown: `basic` (the tiles and the summary cards) or `advanced` (the
  /// message-activity and server-history charts as well). The app's `HomeModel.Detail` is
  /// the vocabulary; this is its stored spelling.
  ///
  /// Here rather than in `UserDefaults` for the reason `onboardingComplete` gives: it is a
  /// preference about THIS server's page, and a redirected support directory must not reach
  /// the real installation's. Hidden, because the toggle on Home is its only control.
  public static let homeDetail = Setting<String>(
    "home_detail", default: "basic"
  )

  // MARK: TLS material provenance
  //
  // Where a certificate CAME FROM, and when it expires. The Electron server encodes both by
  // the presence or absence of `Certs/expiration.txt`: the file is written only when it
  // generated the certificate, so its ABSENCE means "the user installed this, never touch
  // it". That is the correct fail-safe direction and an unreadable way to express it: a
  // missing file is indistinguishable from a deleted one, and it cannot survive the move
  // into the Keychain, which has no files.
  //
  // Stated explicitly instead, and NOT secret: neither value discloses anything, and putting
  // them in the Keychain would make them unreadable in exactly the situation where a person
  // is trying to work out why their certificate was replaced.

  /// `selfSigned` or `imported`. Anything else (including absent) means imported, because
  /// that is the value that stops the renewer touching it.
  public static let tlsCertificateOrigin = Setting<String>(
    "tls_certificate_origin", default: ""
  )

  /// Epoch seconds. Only meaningful for a self-signed certificate; renewal needs a date, and
  /// an unknown one must not be read as "expired" and trigger a regeneration.
  public static let tlsCertificateExpiresAt = Setting<Int>(
    "tls_certificate_expires_at", default: 0
  )

  /// The Firebase remote-restart channel.
  ///
  /// Defaults ON, because a shipping client has a restart button and turning it off by
  /// default would break it: the compatibility contract outranks the hardening here. What
  /// the switch is for is the user who never presses that button and would rather close
  /// vulnerability #1 outright: the document stays world-writable (locking it is what would
  /// break the button), so with this off nothing polls it and a forged command reaches
  /// nothing. With it on, the DoS is bounded rather than open: one restart an hour,
  /// freshness-checked, and alerted.
  ///
  /// No `presentation`: the control lives on the Firebase page, next to the project it
  /// governs, and is bound through `PushInterface.setRemoteRestartEnabled`. It carried a
  /// presentation for a "Notifications" section that never listed it, which made it look
  /// renderable while nothing rendered it.
  public static let remoteRestartEnabled = Setting<Bool>("remote_restart_enabled", default: true)
}
