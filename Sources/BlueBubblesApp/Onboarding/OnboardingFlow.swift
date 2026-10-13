//  OnboardingFlow
//  What setup asks, in what order, and why: as data.
//
//  The first question is "what will you use this server for", and everything after it is
//  decided by the answer: an Android phone needs a tunnel and Firebase for notifications, a
//  desktop client on the same network needs neither, a webhook consumer needs an endpoint
//  registered and nothing about reachability at all. Rather than a wizard that hard-codes
//  those branches in its view, the branches are declared here as a catalogue of steps, each
//  with a rule saying when it is part of the plan, and the view walks whatever the plan is.
//
//  Adding a screen is three edits: a case in `OnboardingStep.ID`, an entry in
//  `OnboardingCatalog.steps`, and a view in `OnboardingStepView`. The switch in the view is
//  exhaustive, so forgetting the third is a compile error rather than a step with no screen.
//
//  Deliberately NOT a View, so every rule below can be asserted from a test process:
//  touching a SwiftUI `View` type from a test traps, which is the same reason
//  `AlertActionRouting` and `IntegrationCatalog` are their own files.
//
//  See `.claude/docs/architecture.md`: The app.

import BBCore
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import Foundation

// MARK: - The first question

/// How the person intends to use the server. Several may be true at once.
enum UsageGoal: String, CaseIterable, Identifiable, Codable, Sendable {
  case android, desktop, api, webhooks
  /// An assistant driving the server. Today that is the HTTP API; the MCP server that will
  /// sit beside it is the next step this goal grows; see `OnboardingCatalog`.
  case aiAgent
  case other

  var id: String { rawValue }

  var title: String {
    switch self {
    case .android: "Android app"
    case .desktop: "Desktop client"
    case .api: "The REST API"
    case .webhooks: "Webhooks"
    case .aiAgent: "AI agent"
    case .other: "Something else"
    }
  }

  var summary: String {
    switch self {
    case .android: "iMessage on an Android phone, with notifications when you're away."
    case .desktop: "The BlueBubbles app on Windows, Linux, or another Mac."
    case .api: "Your own scripts or software talking to this Mac over HTTP."
    case .webhooks: "Push new messages and events to a URL you run."
    case .aiAgent: "Let an assistant read and send messages through this Mac."
    case .other: "Home automation, a bot, or you're not sure yet."
    }
  }

  var symbol: String {
    switch self {
    case .android: "candybarphone"
    case .desktop: "desktopcomputer"
    case .api: "chevron.left.forwardslash.chevron.right"
    case .webhooks: "arrow.up.right.square"
    case .aiAgent: "brain"
    case .other: "sparkles"
    }
  }
}

// MARK: - What has been chosen

/// The answers that shape the plan. Persisted, so a re-run of setup starts where it left off
/// and the Home screen can tailor what it shows.
struct OnboardingSelections: Equatable, Codable, Sendable {
  var goals: Set<UsageGoal> = []
  /// The connection method chosen on the connection step, by service id. Read back from the
  /// settings store rather than trusted from memory, because the settings screen can change
  /// it too.
  var connectionMethod: String?
  /// Whether the Private API is on for Messages, mirrored from the settings store. Nil
  /// until read. Decides whether the group-chat Shortcut step is needed.
  var messagesPrivateAPI: Bool?

  /// Whether the goals have already been seeded from what the server itself holds.
  ///
  /// Once per set of answers, not once per appearance: seeding on every appearance would
  /// re-tick a box the person had deliberately cleared, and seeding never would leave a
  /// migrated install asking what it is already doing. `OnboardingModel.reset` builds a
  /// fresh value, so Start Over seeds again, which is what starting over means.
  ///
  /// OPTIONAL rather than `Bool = false`, and that is about decoding rather than about the
  /// value: a synthesised `Decodable` throws on a missing non-optional key even when the
  /// property has a default, and `OnboardingModel.init` decodes with `try?` — so adding a
  /// non-optional here would silently discard every saved answer on the first launch after
  /// the upgrade. Nil means "not seeded", same as false.
  var hasSeededGoalsFromServer: Bool?

  static let defaultsKey = "onboardingSelections"
}

/// What Firebase is for, given the goals. The wording on the Firebase step comes from this.
enum FirebaseRole: Equatable, Sendable {
  /// Push notifications for a phone, and the server address when it changes.
  case notifications
  /// Only the address. Desktop clients hear about messages over the socket, so Firebase's
  /// one job is to tell them where the server went when a tunnel reconnects.
  case addressUpdates

  var title: String {
    switch self {
    case .notifications: "Notifications and address updates"
    case .addressUpdates: "Address updates"
    }
  }

  var explanation: String {
    switch self {
    case .notifications:
      "The Android app needs Firebase for two things: waking the phone when a message "
        + "arrives, and finding this server again when its address changes. Without it, "
        + "messages only appear while the app is open."
    case .addressUpdates:
      "Desktop clients receive messages over a live connection, so they need no push "
        + "notifications. What they do need is to find this server again when its address "
        + "changes — a new tunnel URL, or a different address on your network after a "
        + "router restart. Firebase is where the server publishes the new one, and how a "
        + "client picks it up without you typing it in."
    }
  }
}

// MARK: - Whether a step may be left

/// Whether Continue is allowed on a step, and what to say if it is not.
enum OnboardingGate: Equatable, Sendable {
  case open
  /// Allowed, with something worth saying first: a binary not yet downloaded.
  case openWithNote(String)
  case blocked(String)

  var isOpen: Bool {
    if case .blocked = self { return false }
    return true
  }

  var message: String? {
    switch self {
    case .open: nil
    case .openWithNote(let note), .blocked(let note): note
    }
  }
}

/// The live facts a gate decides on. Built by the view from the model on every render, so a
/// gate is a pure function and can be tested with a struct.
///
/// One group per gate, and a gate is handed its own group and nothing else, so what a step
/// decides on is in its signature. A gated step adds a group here, a field for it, and the
/// line in `OnboardingView.progress` that fills it.
struct OnboardingProgress: Equatable, Sendable {
  var permissions = Permissions()
  var connection = Connection()

  /// What `OnboardingRules.permissionsGate` reads.
  struct Permissions: Equatable, Sendable {
    var unmetRequired: [String] = []
    var acknowledgedSkip = false
  }

  /// What `OnboardingRules.connectionGate`, and its password half, read.
  struct Connection: Equatable, Sendable {
    /// Nil when the typed password passes policy; empty when nothing has been typed.
    var passwordProblem: String? = ""
    /// Whether a connection method has to be chosen on this walk. See
    /// `OnboardingRules.needsConnectionMethod`.
    var requiresMethod = true
    var method: String?
    var methodName: String?
    var missingFields: [String] = []
    var toolMissing = false
    var toolName: String?
    /// The person ticked "set this up later" over a program that is not on this Mac yet.
    var acknowledgedToolSkip = false
  }
}

// MARK: - A step

struct OnboardingStep: Identifiable, Sendable {

  enum ID: String, CaseIterable, Sendable {
    case welcome, goals, permissions, connection, firebase, webhooks, api, privateAPI
    case groupShortcut, search, finish
  }

  let id: ID
  let title: String
  let symbol: String
  /// One sentence under the title. Takes the selections so a step can say WHY it is here
  /// for this person: the Firebase step reads differently for a phone and a desktop.
  let purpose: @Sendable (OnboardingSelections) -> String
  /// Whether the step is in the plan for these selections.
  let isIncluded: @Sendable (OnboardingSelections) -> Bool
  /// Whether "Skip for now" is offered. A step someone can come back to in settings.
  let isSkippable: Bool
  /// The step's content scrolls on its own (it embeds a full page), so the shell must not
  /// wrap it in a second ScrollView.
  let scrollsItself: Bool
  let gate: @Sendable (OnboardingProgress) -> OnboardingGate

  init(
    _ id: ID,
    title: String,
    symbol: String,
    purpose: @escaping @Sendable (OnboardingSelections) -> String,
    isIncluded: @escaping @Sendable (OnboardingSelections) -> Bool = { _ in true },
    isSkippable: Bool = false,
    scrollsItself: Bool = false,
    gate: @escaping @Sendable (OnboardingProgress) -> OnboardingGate = { _ in .open }
  ) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.purpose = purpose
    self.isIncluded = isIncluded
    self.isSkippable = isSkippable
    self.scrollsItself = scrollsItself
    self.gate = gate
  }
}

// MARK: - The rules

enum OnboardingRules {

  /// The goals a server's OWN STATE already implies, for a walkthrough that is reviewing a
  /// configured install rather than setting up a blank one.
  ///
  /// **The walkthrough runs after a migration too, and it should agree with the server it
  /// is describing.** An adopted Electron install arrives with a password, a connection
  /// method, registered devices and webhooks; a goals step that starts empty asks the
  /// person to re-declare what the server in front of them is visibly already doing, and
  /// then reshapes the rest of the walk around the empty answer.
  ///
  /// Three signals, and each is a thing somebody DID rather than a guess about them:
  ///
  ///   - a push registration exists, so a phone asked to be woken. FCM is Android's alone
  ///     here — a desktop client reads the socket and is never sent a push — so a `device`
  ///     row is the Android app or something behaving like it.
  ///   - Firebase has a service account, which is what makes the server able to republish
  ///     its address. That is the half of Firebase the DESKTOP client uses: it watches for
  ///     the new address rather than being woken by a push. Same project, different
  ///     mechanism; `FirebaseRole` is where the distinction is spelled out.
  ///   - a webhook exists, which somebody typed a URL to create.
  ///
  /// The Firebase signal can over-tick: a server set up for Android alone also has a
  /// service account, so it implies `.desktop` too. That is accepted rather than
  /// overlooked. The cost is one box to untick on a step whose whole purpose is to be
  /// adjusted, and the alternative — Firebase configured and the desktop box empty — asks
  /// somebody to re-declare what their server is visibly already doing.
  ///
  /// `.api`, `.aiAgent` and `.other` are still NOT inferred, and the reason is unchanged:
  /// nothing a script or an assistant does leaves a mark distinguishable from any other
  /// HTTP client, so the only honest inference is none.
  static func goalsImpliedByExistingState(
    pushDevices: Int, webhooks: Int, firebaseConfigured: Bool
  ) -> Set<UsageGoal> {
    var implied: Set<UsageGoal> = []
    if pushDevices > 0 { implied.insert(.android) }
    if firebaseConfigured { implied.insert(.desktop) }
    if webhooks > 0 { implied.insert(.webhooks) }
    return implied
  }

  /// Whether anyone will connect TO this server, which is what a connection method is for.
  ///
  /// Webhooks are outbound (the server calls the URL) so a webhook-only setup never needs
  /// to be reachable. Everything else does, including "something else" and an AI agent: a
  /// bot, an automation or an assistant is a client of the HTTP API.
  static func needsConnectionMethod(_ goals: Set<UsageGoal>) -> Bool {
    !goals.isEmpty && goals != [.webhooks]
  }

  /// Whether the port is worth asking about.
  ///
  /// The password is always required (the server refuses every request without one, and
  /// a webhook consumer may add a client later) but the port only matters to something
  /// that connects to the HTTP API or the socket. A webhook-only setup is outbound, so the
  /// question would be noise.
  static func asksForPort(_ goals: Set<UsageGoal>) -> Bool {
    needsConnectionMethod(goals)
  }

  /// What Firebase would do for these selections, or nil if it would do nothing useful.
  ///
  /// Only the two client apps are ever a reason. The API, webhooks and an agent have no
  /// phone to wake and nothing listening for an address to be republished.
  ///
  /// **The two clients use Firebase for two different things, and only one of them is
  /// FCM.** An Android phone needs a push message to wake it when iMessage arrives — that
  /// is FCM, that is what a `device` row is, and it is Android's alone. A desktop client is
  /// already connected over a socket and needs no waking; what it needs is to be told where
  /// the server WENT, which it learns by watching the document the server republishes its
  /// address into. Same project, different mechanism.
  ///
  /// So desktop always gets the step. It used to be gated on whether the connection
  /// method's address could change, read from the manifest as "does it run a program", and
  /// that gate was wrong: it put LAN in the same class as a hostname the person owns. A LAN
  /// address is a DHCP lease, not property — it moves when the router reassigns it, when
  /// the Mac changes network, and when a VPN takes over the primary interface, which is the
  /// case the LAN method's own address picker exists to cope with. The step is skippable; a
  /// desktop client that cannot find the server after it moves is not.
  static func firebaseRole(for selections: OnboardingSelections) -> FirebaseRole? {
    if selections.goals.contains(.android) { return .notifications }
    return selections.goals.contains(.desktop) ? .addressUpdates : nil
  }

  /// Whether group chat creation needs the Shortcut.
  ///
  /// Without the Private API for Messages, macOS gives no way to create a group chat except
  /// a Shortcut: AppleScript lost its group path three releases below our floor. Unknown
  /// counts as "not on": the step is cheap to skip and expensive to have missed.
  static func needsGroupChatShortcut(_ selections: OnboardingSelections) -> Bool {
    selections.messagesPrivateAPI != true
  }

  /// The permission gate: unmet required permissions block until the skip is acknowledged.
  static func permissionsGate(_ facts: OnboardingProgress.Permissions) -> OnboardingGate {
    guard !facts.unmetRequired.isEmpty else { return .open }
    if facts.acknowledgedSkip {
      return .openWithNote(
        "Continuing without \(facts.unmetRequired.joined(separator: ", ")). "
          + "The features that need them will not work until they are granted.")
    }
    return .blocked(
      "Grant \(facts.unmetRequired.joined(separator: ", ")), or tick the box "
        + "to continue without them.")
  }

  /// Whether a typed password is acceptable, given whether one is already stored.
  ///
  /// Nil means acceptable; a string is the reason to show; empty means "nothing typed yet".
  ///
  /// **An empty field over an EXISTING password means "keep it", and that is the case this
  /// exists for.** Re-running the Setup Assistant months later (to add a phone, say) walks
  /// through this step, and requiring a value there would force the person to replace a
  /// password their clients are already using: every paired client disconnects, for a step
  /// they opened for an unrelated reason. A migrated password is deliberately accepted
  /// however weak it is, matching `LegacyConfigMigration`, which does not run the policy
  /// over one either; the Security page is where strength is reported.
  ///
  /// A pure function here rather than a computed property on the view, so it can be tested:
  /// a `View` cannot be instantiated in a test process, which is why the rest of this file
  /// is shaped the same way.
  static func passwordRejection(
    typed: String,
    hasStoredPassword: Bool,
    policy: PasswordPolicy = PasswordPolicy()
  ) -> String? {
    guard !typed.isEmpty else { return hasStoredPassword ? nil : "" }
    do {
      try policy.validate(typed)
      return nil
    } catch {
      // `PasswordPolicy.Rejection` is a `BBError` whose body is its `userMessage`, so the one
      // rule reaches the policy's own sentence; anything else is rendered for a person too,
      // never as a Swift value dumped into the step.
      return DiagnosticText.sentence(for: error)
    }
  }

  /// The password half of the connection gate. An empty password is not "no
  /// authentication": the server refuses every request, so this cannot be walked past.
  static func passwordGate(_ facts: OnboardingProgress.Connection) -> OnboardingGate {
    guard let problem = facts.passwordProblem else { return .open }
    return .blocked(
      problem.isEmpty
        ? "A password is required. Without one the server rejects every client." : problem)
  }

  /// The connection gate: the password must pass, and where something will connect a
  /// method must be chosen with its required fields filled and its program on the Mac.
  ///
  /// **A missing program blocks, and used to be a note.** As a note it read "Tailscale needs
  /// the Tailscale program, which is not downloaded yet", with Continue live beside it: the
  /// person who reported this took Continue, because that is what a live Continue means, and
  /// finished setup with a connection method that could never start. The download button is
  /// on this step, below the fold under "Required Program", which is the other half of the
  /// problem: nothing said there was anything further down.
  ///
  /// **It is acknowledged rather than hard-blocked**, and that is the same shape
  /// `permissionsGate` uses, for the same reason. A download can fail for reasons the person
  /// cannot fix now (no network, the vendor's release host down, no build for this Mac's
  /// architecture) and this step is NOT skippable, so a hard block would leave Quit as the
  /// only way out of setup. The tick box costs one deliberate action and leaves a note
  /// saying what will not work.
  static func connectionGate(_ facts: OnboardingProgress.Connection) -> OnboardingGate {
    let password = passwordGate(facts)
    guard password.isOpen else { return password }
    guard facts.requiresMethod else { return .open }
    guard let name = facts.methodName, facts.method != nil else {
      return .blocked("Choose how clients will reach this Mac.")
    }
    if !facts.missingFields.isEmpty {
      return .blocked("\(name) needs: " + facts.missingFields.joined(separator: ", "))
    }
    if facts.toolMissing {
      let program = facts.toolName ?? "required"
      if facts.acknowledgedToolSkip {
        return .openWithNote(
          "Continuing without \(program). \(name) will not start, and nothing will be able "
            + "to reach this Mac, until it is installed under Settings › Integrations.")
      }
      // Names WHERE, because the button is below the fold on this same step and the note
      // that did not say so is the report this came from.
      return .blocked(
        "\(name) needs the \(program) program, which is not on this Mac yet. Install it "
          + "under \u{201C}Required Program\u{201D} below, or tick the box to continue "
          + "without it.")
    }
    return .open
  }
}

// MARK: - The catalogue

enum OnboardingCatalog {

  /// Every step there is, in the order they can appear. The plan is this list filtered.
  static let steps: [OnboardingStep] = [
    OnboardingStep(
      .welcome, title: "Welcome", symbol: "hand.wave",
      purpose: { _ in "BlueBubbles gives your other devices access to iMessage on this Mac." }
    ),
    OnboardingStep(
      .goals, title: "How will you use it?", symbol: "checklist",
      purpose: { _ in "Pick everything that applies. Setup only asks about what you chose." },
      gate: { _ in .open }
    ),
    OnboardingStep(
      .permissions, title: "Permissions", symbol: "hand.raised",
      purpose: { _ in
        "The server reads the Messages database and drives the Messages app, which "
          + "macOS gates behind these."
      },
      gate: { OnboardingRules.permissionsGate($0.permissions) }
    ),
    OnboardingStep(
      .connection, title: "Connection", symbol: "network",
      purpose: { selections in
        if !OnboardingRules.needsConnectionMethod(selections.goals) {
          return "A password is required even when nothing connects yet: the server refuses "
            + "every request without one, and it protects the API the moment something does."
        }
        return selections.goals.contains(.android)
          ? "The password every client authenticates with, and a way for a phone to reach "
            + "this Mac from anywhere."
          : "The password every client authenticates with, and how clients reach this Mac: "
            + "on your network, or through a tunnel."
      },
      gate: { OnboardingRules.connectionGate($0.connection) }
    ),
    OnboardingStep(
      .firebase, title: "Firebase", symbol: "bell.badge",
      purpose: { selections in
        OnboardingRules.firebaseRole(for: selections)?.explanation ?? ""
      },
      isIncluded: { OnboardingRules.firebaseRole(for: $0) != nil },
      isSkippable: true,
      scrollsItself: true
    ),
    OnboardingStep(
      .webhooks, title: "Webhooks", symbol: "arrow.up.right.square",
      purpose: { _ in
        "Register the URL that should receive events. You can add more later under "
          + "API & Webhooks."
      },
      isIncluded: { $0.goals.contains(.webhooks) },
      isSkippable: true,
      scrollsItself: true
    ),
    OnboardingStep(
      .api, title: "Using the API", symbol: "chevron.left.forwardslash.chevron.right",
      purpose: { selections in
        selections.goals.contains(.aiAgent) && !selections.goals.contains(.api)
          ? "Where an agent points today. An MCP server that sits beside the HTTP API is "
            + "planned; until it ships, the REST API is the way in."
          : "Where to point your code, and where the reference lives."
      },
      isIncluded: { $0.goals.contains(.api) || $0.goals.contains(.aiAgent) },
      isSkippable: true
    ),
    // ROOM TO GROW: the MCP server. When it exists as a service, it gets a step here:
    // `.mcp`, included for `.aiAgent`, embedding that service's own form the way
    // `.connection` embeds the tunnel's, and the API step above stops mentioning it.
    OnboardingStep(
      .privateAPI, title: "Private API", symbol: "wand.and.rays",
      purpose: { _ in
        // Both apps named, because both toggles are on this step. They are separate
        // helpers in separate apps and either works without the other; see
        // `PrivateAPIGatedService.canRun()`, so "and" here would be wrong.
        "Reactions, editing, unsending, typing indicators and group management in Messages; "
          + "links, outgoing calls and hand-off in FaceTime. Both are optional, either can "
          + "be used without the other, and both need System Integrity Protection disabled."
      },
      isSkippable: true
    ),
    OnboardingStep(
      .groupShortcut, title: "Group chats", symbol: "person.3",
      purpose: { _ in
        "Without the Private API, the only way this Mac can create a group chat is a "
          + "Shortcut. Install it now so the feature works from the first message."
      },
      isIncluded: OnboardingRules.needsGroupChatShortcut,
      isSkippable: true
    ),

    /// Offered to everyone, and last before the summary.
    ///
    /// After the connection and delivery steps because nothing depends on it, and a person
    /// setting the server up should reach a WORKING server before being asked to weigh a
    /// privacy trade. After the group-chat step because that one has to stay immediately
    /// behind the Private API offer, whose answer decides whether it appears at all.
    ///
    /// NOT skippable, and that is not an oversight. A Skip button implies an unfinished task;
    /// this step is a CHOICE with a default, and Continue is how the default is accepted.
    /// Adding Skip would give one decision two decline buttons.
    OnboardingStep(
      .search, title: "Search", symbol: "magnifyingglass",
      purpose: { _ in
        // States the problem, not the feature. Somebody reading this has not noticed
        // anything wrong yet, and "turn on the search index" means nothing to them; "your
        // messages cannot be searched" is the thing they would actually care about.
        "Recent versions of macOS stopped storing the words of a message where other apps "
          + "can read them, so searching your message text finds almost nothing. BlueBubbles "
          + "can fix that on this Mac."
      }
    ),

    OnboardingStep(
      .finish, title: "All set", symbol: "checkmark.seal",
      purpose: { _ in "A few preferences, and you're done." }
    ),
  ]

  /// The settings offered on the last step, rendered by the same rows the settings screen
  /// uses. Add one here and it appears; nothing else changes.
  static var finishSettingKeys: [String] {
    [
      Settings.autoStartMethod.key,
      Settings.checkForUpdates.key,
      // Beside the check, because it is the answer for the Mac nobody sits at: the update
      // installs itself at night rather than waiting for someone to notice a window.
      Settings.autoInstallUpdates.key,
      Settings.startMinimized.key,
    ]
  }
}

enum OnboardingPlan {
  /// The steps this person walks, in order.
  static func steps(for selections: OnboardingSelections) -> [OnboardingStep] {
    OnboardingCatalog.steps.filter { $0.isIncluded(selections) }
  }
}
