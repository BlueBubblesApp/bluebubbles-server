//  SettingsRegistry+Behaviour
//  How the server behaves once it is reachable: search, start-up, polling, the dock, the
//  Find My window and the landing page.
//
//  Its own file so a reader tuning the server opens these declarations and not the rest of
//  the registry. The lists that make a setting exist (`Settings.renderable`,
//  `Settings.hidden`) stay in `SettingsRegistry.swift`.

import Foundation

extension Settings {

  // MARK: - Behaviour

  /// Whether this Mac keeps a searchable word list of message text.
  ///
  /// **Off, and the default is the feature's whole security posture rather than caution.**
  /// With it off the server persists no message content anywhere, which is what it does
  /// today; nobody who does not choose this acquires a new exposure, upgrades included.
  ///
  /// The reason it exists at all: macOS 26 stopped populating `message.text`, so the words
  /// live in `attributedBody` where a SQL `LIKE` cannot reach them and a search finds almost
  /// nothing sent since the update. Measured on a real database, 99.8% of one month's
  /// messages have an empty `text` column, incoming as well as outgoing. `chat.db` carries no
  /// index to borrow and the text Messages donates goes to a CoreSpotlight domain only
  /// Messages' own process can query, so an index of our own is the only route that does not
  /// need the Private API.
  ///
  /// A plain setting and NOT a `FeatureFlag`, which is a closer call than it looks. The flags
  /// gate API surface a client can detect — both of them add endpoints — and this adds none:
  /// `/message/query` already takes the `where` clause this improves the answers to. It is
  /// also configured during onboarding, which `FeatureFlags`' own header puts on the plain
  /// setting side of the line.
  ///
  /// Turning it off is not a pause. `SearchIndexStore.destroy()` removes the file, because
  /// "turning this off deletes it" is in the copy the user is shown and has to be true.
  ///
  /// See `docs/SEARCH.md`.
  public static let searchIndexEnabled = Setting<Bool>(
    "search_index_enabled", default: false,
    presentation: .init(
      label: "Message Search Index",
      // WHY it is needed is the section's subtitle, and WHAT it holds is the status card
      // under this row. What is left for the row is what turning it on does, which is all
      // a row beside a switch can usefully carry.
      help: "Reads your history once, here on this Mac. It takes about a minute, nothing "
        + "is uploaded, and turning it off deletes the index.",
      section: .features, control: .toggle, isInternal: true)
  )

  /// A real Double. The Electron default is the string "0.0" purely to survive its own
  /// type coercion: the reference's own comment on the default says so outright.
  public static let startDelay = Setting<Double>(
    "start_delay", default: 0,
    validate: { value in
      guard value >= 0, value <= 600 else {
        throw SettingsError.validationFailed(key: "start_delay", reason: "must be 0-600 seconds")
      }
    },
    presentation: .init(
      label: "Startup Delay", section: .features, control: .number(range: 0...600))
  )

  /// How many chat.db reads may be in flight at once.
  ///
  /// **One by default**: a single SQLite connection, every read serialised through it:
  /// HTTP routes, the change detector's poll and the app alike.
  /// `Tests/BBIMessageTests/ReadConcurrencyBenchmark.swift` measures what that costs. On a
  /// 40,000-message database, page queries stay flat from one concurrent reader to sixteen
  /// through a single connection, while a pool of four roughly doubles under contention. The
  /// ceiling is real, and multi-client is the normal case here.
  ///
  /// **Measured 2026-09-14: MacBook Pro M3 Max, macOS 26.5.2, arm64, release build.**
  /// queue(1) held 559-592 queries/second at every concurrency level; pool(4) went from 550
  /// at one reader to 1,096 at sixteen. Pool memory was +0.0 MB against a 29.5 MB baseline.
  ///
  /// Those conditions are stated because the previous figures here had none, and were wrong:
  /// "~26/second", "~95/second" and "about 2 MB" for the pool. Re-measuring gave twenty times
  /// the throughput and no measurable memory, and even the RATIO was off -- 3.7x claimed
  /// against 1.9x measured. A number with no machine beside it cannot be checked, and this
  /// one went unchecked long enough to be quoted as a settled fact. The suite's own
  /// `poolMemoryCost` test had been printing +0.0 MB all along; nobody compared the two.
  ///
  /// Expect a different answer on the hardware this server is often deployed to. This Mac
  /// has an NVMe fast enough that a single connection is rarely waiting on the disk, which
  /// is precisely the wait a pool exists to overlap; on a SATA or spinning disk the pool
  /// should help more, not less. Nobody has measured that.
  ///
  /// It stays at one by default anyway, because changing it changes behaviour on every
  /// existing install, and the numbers above come from one synthetic workload (deep-offset
  /// paging over a single chat) rather than from the field. Raising the default is a
  /// decision to take on evidence from real servers, not from this benchmark alone.
  public static let chatDatabaseReaders = Setting<Int>(
    "chat_db_readers", default: 1,
    application: .composition,
    presentation: .init(
      label: "Concurrent Database Readers",
      help: "How many message-database reads run at once. 1 is the safe default; raising it "
        + "helps when several clients are active, and costs memory per reader.",
      section: .advanced, control: .number(range: 1...8))
  )

  /// Also a real Int. Under the reference's coercion a value of 0 or 1 comes back as a Bool.
  ///
  /// The key is the Electron server's poll period. Here it is the period of the BACKUP
  /// check: `PRAGMA data_version` asked whether the file watcher missed a
  /// commit, and changes are detected by the watcher the moment the file is written. The
  /// minimum is 30 seconds because anything shorter is polling again; a legacy value below
  /// it is raised on migration, and `ChangeDetectionService` clamps whatever it reads.
  public static let dbPollInterval = Setting<Int>(
    "db_poll_interval", default: 30_000,
    validate: { value in
      guard value >= 30_000 else {
        throw SettingsError.validationFailed(
          key: "db_poll_interval", reason: "minimum is 30 seconds (30000ms)")
      }
    },
    presentation: .init(
      label: "Backup Check Interval (ms)",
      help: "How often the server double-checks the message database for a change the file "
        + "watcher missed. Changes are normally noticed the instant the file is written; "
        + "this only bounds how late a missed one can be. Minimum 30 seconds.",
      section: .advanced, control: .number(range: 30_000...600_000))
  )

  public static let autoCaffeinate = Setting<Bool>(
    "auto_caffeinate", default: false,
    presentation: .init(label: "Keep Mac Awake", section: .features, control: .toggle))
  /// Off by default. Registering a login item is something a user opts into: a server that
  /// silently starts itself after an install is a surprise, and an unwelcome one on a Mac
  /// someone else also uses.
  public static let autoStartMethod = Setting<AutoStartMethod>(
    "auto_start_method", default: .none,
    presentation: .init(
      label: "Start at Login",
      help: "Runs the server automatically when you log in to this Mac.",
      section: .features,
      control: .picker(
        options: AutoStartMethod.choices.map { .init(value: $0.rawValue, label: $0.label) }
      )
    ))
  public static let startMinimized = Setting<Bool>(
    "start_minimized", default: false,
    presentation: .init(label: "Start Minimized", section: .features, control: .toggle))
  public static let hideDockIcon = Setting<Bool>(
    "hide_dock_icon", default: false,
    presentation: .init(label: "Hide Dock Icon", section: .features, control: .toggle))
  public static let dockBadge = Setting<Bool>(
    "dock_badge", default: true,
    presentation: .init(label: "Show Dock Badge", section: .features, control: .toggle))
  public static let autoLockMac = Setting<Bool>(
    "auto_lock_mac", default: false,
    presentation: .init(label: "Lock Mac on Start", section: .features, control: .toggle))
  /// OFF. Launching another application is not something a server does to someone's Mac
  /// without being asked, and on most supported releases it buys nothing anyway.
  ///
  /// What it does: opens FindMy.app so it rewrites the caches under
  /// `~/Library/Caches/com.apple.findmy.fmipcore` that `BBSystem.FindMy` reads. What it does
  /// NOT do, despite the name being the only documentation it used to have:
  ///
  /// - **Nothing for friends.** `FindMyInterface.refreshFriends` runs `throughMessages`
  ///   against the helper injected into Messages. FindMy.app is not a helper host — see
  ///   `HelperHost`, which is Messages and FaceTime — so whether it is running is irrelevant.
  /// - **Nothing on Sequoia or newer.** Apple encrypted `Devices.data` in 15, so
  ///   `FindMy.cacheIsEncrypted` makes `/findmy/devices` answer `null` whatever the cache
  ///   holds. The refresh it triggers cannot be read back.
  ///
  /// That leaves Sonoma device caches, which is a real but narrow use, and is why the switch
  /// survives rather than the behaviour being deleted.
  ///
  /// The reference's key of this name means something else: it gates whether a FRIENDS
  /// refresh may open the app, is read only in `MessagesDylibPlugin.injectPlugin`, and only
  /// when the friends cache is empty. Nothing here reproduces that, and nothing should
  /// without a reason a client can observe — its own Private-API friends path is gated
  /// `isMinBigSur && !isMinSonoma`, which is entirely below this server's floor.
  public static let openFindMyOnStartup = Setting<Bool>(
    "open_findmy_on_startup", default: false,
    presentation: .init(
      label: "Open FindMy on Startup",
      help: "Opens the FindMy app when the server starts, so it refreshes the device cache "
        + "this server reads. Does nothing on macOS 15 and newer, where Apple encrypts that "
        + "cache, and nothing for Find My friends on any release.",
      section: .features,
      control: .toggle
    ))
  /// An HTML file served at `GET /` in place of the built-in page.
  ///
  /// `LandingHandlers` reads it; this row is how it gets set.
  public static let landingPagePath = Setting<String>(
    "landing_page_path", default: "",
    presentation: .init(
      label: "Custom Landing Page",
      help: "An HTML file to serve at the server's root address instead of the default "
        + "page. Leave empty for the built-in one.",
      section: .features,
      control: .path
    ))
}
