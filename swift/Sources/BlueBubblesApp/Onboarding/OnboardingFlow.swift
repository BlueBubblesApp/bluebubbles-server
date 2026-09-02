//  OnboardingFlow
//  What setup asks, in what order, and why — as data.
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
//  Deliberately NOT a View, so every rule below can be asserted from a test process —
//  touching a SwiftUI `View` type from a test traps, which is the same reason
//  `AlertActionRouting` and `IntegrationCatalog` are their own files.
//
//  See `.claude/docs/architecture.md` — The app.

import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import Foundation

// MARK: - The first question

/// How the person intends to use the server. Several may be true at once.
enum UsageGoal: String, CaseIterable, Identifiable, Codable, Sendable {
  case android, desktop, api, webhooks
  /// An assistant driving the server. Today that is the HTTP API; the MCP server that will
  /// sit beside it is the next step this goal grows — see `OnboardingCatalog`.
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
      "Desktop clients receive messages over a live connection, so Firebase is not needed "
        + "for notifications. Your connection method's address can change between "
        + "restarts, though, and Firebase is how a client learns the new one without you "
        + "typing it in."
    }
  }
}

// MARK: - Whether a step may be left

/// Whether Continue is allowed on a step, and what to say if it is not.
enum OnboardingGate: Equatable, Sendable {
  case open
  /// Allowed, with something worth saying first — a binary not yet downloaded.
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
struct OnboardingProgress: Equatable, Sendable {
  var unmetRequiredPermissions: [String] = []
  var acknowledgedPermissionSkip = false
  /// Nil when the typed password passes policy; empty when nothing has been typed.
  var passwordProblem: String? = ""
  /// Whether a connection method has to be chosen on this walk. See
  /// `OnboardingRules.needsConnectionMethod`.
  var requiresConnectionMethod = true
  var connectionMethod: String?
  var connectionMethodName: String?
  var missingConnectionFields: [String] = []
  var connectionToolMissing = false
  var connectionToolName: String?
}

// MARK: - A step

struct OnboardingStep: Identifiable, Sendable {

  enum ID: String, CaseIterable, Sendable {
    case welcome, goals, permissions, connection, firebase, webhooks, api, privateAPI
    case groupShortcut, finish
  }

  let id: ID
  let title: String
  let symbol: String
  /// One sentence under the title. Takes the selections so a step can say WHY it is here
  /// for this person — the Firebase step reads differently for a phone and a desktop.
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

  /// Whether anyone will connect TO this server, which is what a connection method is for.
  ///
  /// Webhooks are outbound — the server calls the URL — so a webhook-only setup never needs
  /// to be reachable. Everything else does, including "something else" and an AI agent: a
  /// bot, an automation or an assistant is a client of the HTTP API.
  static func needsConnectionMethod(_ goals: Set<UsageGoal>) -> Bool {
    !goals.isEmpty && goals != [.webhooks]
  }

  /// Whether the port is worth asking about.
  ///
  /// The password is always required — the server refuses every request without one, and
  /// a webhook consumer may add a client later — but the port only matters to something
  /// that connects to the HTTP API or the socket. A webhook-only setup is outbound, so the
  /// question would be noise.
  static func asksForPort(_ goals: Set<UsageGoal>) -> Bool {
    needsConnectionMethod(goals)
  }

  /// Whether a connection method's address can change between restarts.
  ///
  /// Read from the manifest, not from a list of tunnel names: a method that runs a program
  /// (or spawns one) is a tunnel whose provider assigns the address, and a method that does
  /// not is a fixed address the person owns. A third-party tunnel gets the right answer
  /// without this file learning its name. An unknown id is assumed to change, which errs
  /// towards offering Firebase rather than silently omitting it.
  static func addressCanChange(connectionMethod id: String?) -> Bool {
    guard let id, let manifest = BuiltInManifests.all.first(where: { $0.id.rawValue == id })
    else { return true }
    return !manifest.tools.isEmpty || manifest.entitlements.contains(.spawnProcess)
  }

  /// What Firebase would do for these selections, or nil if it would do nothing useful.
  ///
  /// Only the two client apps are ever a reason. The API, webhooks and an agent have no
  /// phone to wake and find the server by the address they were given.
  static func firebaseRole(for selections: OnboardingSelections) -> FirebaseRole? {
    if selections.goals.contains(.android) { return .notifications }
    guard selections.goals.contains(.desktop) else { return nil }
    return addressCanChange(connectionMethod: selections.connectionMethod)
      ? .addressUpdates : nil
  }

  /// Whether group chat creation needs the Shortcut.
  ///
  /// Without the Private API for Messages, macOS gives no way to create a group chat except
  /// a Shortcut — AppleScript lost its group path three releases below our floor. Unknown
  /// counts as "not on": the step is cheap to skip and expensive to have missed.
  static func needsGroupChatShortcut(_ selections: OnboardingSelections) -> Bool {
    selections.messagesPrivateAPI != true
  }

  /// The permission gate: unmet required permissions block until the skip is acknowledged.
  static func permissionsGate(_ progress: OnboardingProgress) -> OnboardingGate {
    guard !progress.unmetRequiredPermissions.isEmpty else { return .open }
    if progress.acknowledgedPermissionSkip {
      return .openWithNote(
        "Continuing without \(progress.unmetRequiredPermissions.joined(separator: ", ")). "
          + "The features that need them will not work until they are granted.")
    }
    return .blocked(
      "Grant \(progress.unmetRequiredPermissions.joined(separator: ", ")), or tick the box "
        + "to continue without them.")
  }

  /// The password half of the connection gate. An empty password is not "no
  /// authentication" — the server refuses every request — so this cannot be walked past.
  static func passwordGate(_ progress: OnboardingProgress) -> OnboardingGate {
    guard let problem = progress.passwordProblem else { return .open }
    return .blocked(
      problem.isEmpty
        ? "A password is required. Without one the server rejects every client." : problem)
  }

  /// The connection gate: the password must pass, and where something will connect a
  /// method must be chosen with its required fields filled. A missing binary is a note
  /// rather than a block — it can be downloaded later, and the tunnel reports itself as not
  /// started until then.
  static func connectionGate(_ progress: OnboardingProgress) -> OnboardingGate {
    let password = passwordGate(progress)
    guard password.isOpen else { return password }
    guard progress.requiresConnectionMethod else { return .open }
    guard let name = progress.connectionMethodName, progress.connectionMethod != nil else {
      return .blocked("Choose how clients will reach this Mac.")
    }
    if !progress.missingConnectionFields.isEmpty {
      return .blocked(
        "\(name) needs: " + progress.missingConnectionFields.joined(separator: ", "))
    }
    if progress.connectionToolMissing {
      return .openWithNote(
        "\(name) needs the \(progress.connectionToolName ?? "required") program, which is "
          + "not downloaded yet. The connection will not start until it is.")
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
      gate: OnboardingRules.permissionsGate
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
      gate: OnboardingRules.connectionGate
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
    // ROOM TO GROW: the MCP server. When it exists as a service, it gets a step here —
    // `.mcp`, included for `.aiAgent`, embedding that service's own form the way
    // `.connection` embeds the tunnel's — and the API step above stops mentioning it.
    OnboardingStep(
      .privateAPI, title: "Private API", symbol: "wand.and.rays",
      purpose: { _ in
        "Reactions, editing, unsending, typing indicators and group management. Optional, "
          + "and it needs System Integrity Protection disabled."
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
