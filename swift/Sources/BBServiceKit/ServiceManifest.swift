//  ServiceManifest
//  What a service or plugin declares about itself, before any of its code runs.
//
//  Everything a service is — what it does, what it needs, what it may touch, what it can be
//  configured with — is DATA rather than code. That is the constraint the whole design hangs
//  on, and it is worth being explicit about why: a third-party plugin's manifest will arrive
//  as JSON from somewhere untrusted, and if first-party services describe themselves with
//  Swift closures then plugins can never express the same things. So a manifest holds no
//  behaviour. Behaviour lives in the `Service` implementation; the manifest is what the host
//  reads to decide whether to run it at all, and what to show a user before they agree.
//
//  Services are the seeded plugins: same manifest, same validation, same entitlement rules,
//  distinguished only by shipping enabled and being trusted enough to hold core entitlements.
//  If the built-in set cannot be expressed in this model, the model is wrong — which is why
//  every existing service declares one.
//
//  STATUS: third-party plugins are a planned next step, NOT a current capability.
//
//  Nothing loads an external manifest today. `ServiceManifest` is deliberately not `Codable`
//  yet, there is no loader and no registration path for a service the compiler has not seen,
//  and `Service.init(host:)` requires a Swift type. So the "arrives as JSON from somewhere
//  untrusted" argument above describes what this model is BUILT FOR rather than what
//  currently happens — worth knowing before reading the validation as if it were guarding a
//  live input surface.
//
//  What the validation does earn its keep on meanwhile is the built-in set:
//  `ManifestValidator` runs over every shipped manifest at start-up and catches malformed
//  identifiers, entitlements a built-in may not hold, dependency cycles, form fields with
//  duplicate or dangling keys, and tools declared without a verifiable build. Those are real
//  failures it has to catch whether or not a plugin ever loads.
//
//  Making plugins real means: `Codable` on this type and everything it contains (its nested
//  types already are), a loader that validates BEFORE anything is constructed, and a
//  decision about what an untrusted manifest is allowed to declare.
//
//  FROZEN, deliberately, until that work is picked up.
//
//  Third-party plugins are still wanted; they are not being built now. Until they are, this
//  surface is CLOSED TO NEW CAPABILITY: no new entitlement kinds, no new manifest fields for
//  hypothetical plugin needs, no widening of the tool or migration descriptors. Roughly 1,700
//  lines across this file, `ManifestValidation`, `ToolRequirement`, `ServiceMigration` and
//  `SettingsScope` already serve eleven compiled-in services, and every line of it is tax the
//  built-ins pay for a boundary no process boundary yet enforces.
//
//  What is still fair game while frozen: fixing a bug, and adding a field a BUILT-IN service
//  genuinely needs today. The test is whether a shipping service is blocked without it — not
//  whether a future plugin might want it.
//
//  It has already earned its keep once, and that is why it is frozen rather than deleted:
//  `ProxyServices` models connection methods as manifest-described services rather than an
//  enum, which is the only reason a third-party tunnel is expressible at all.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import Foundation

// MARK: - Identity

/// A stable, reverse-DNS identifier: `app.bluebubbles.proxy.zrok`.
///
/// Distinct from the display name and from `ServiceID` on purpose. This is what the settings
/// namespace and every granted entitlement key on, so it must never change — renaming it
/// orphans the plugin's stored configuration and silently re-prompts for permissions the user
/// already granted.
public struct ServiceIdentifier: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  /// The last path component: `zrok` for `app.bluebubbles.proxy.zrok`.
  ///
  /// This is what `server/info` reports as `proxy_service`, and clients have branched on
  /// those short strings for years — so the internal model moving to a reverse-DNS
  /// identifier must not change what goes out.
  public var shortName: String {
    rawValue.split(separator: ".").last.map(String.init) ?? rawValue
  }

  /// The settings namespace this identifier owns.
  ///
  /// Every key a service writes without an entitlement lives under here, which is what makes
  /// "your own settings" enforceable rather than a convention: ownership is decided by the
  /// key's prefix, not by who happens to be asking.
  public var settingsNamespace: String { "\(rawValue)." }

  /// Whether this is a plausible identifier at all.
  ///
  /// Checked at load rather than trusted, because a third-party manifest supplies it: an id
  /// containing a path separator or a wildcard would let a plugin claim a namespace that is
  /// not its own.
  public var isWellFormed: Bool {
    !rawValue.isEmpty
      && rawValue.count <= 128
      && rawValue.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
      && !rawValue.hasPrefix(".")
      && !rawValue.hasSuffix(".")
      && !rawValue.contains("..")
  }
}

// MARK: - Category

/// What KIND of thing this is, for grouping and for exclusivity.
///
/// A closed enum rather than free text. Free text fragments immediately — "Reverse Proxy",
/// "reverse-proxy", "Proxy" — and the UI groups on this, so three spellings become three
/// sections containing one item each.
public enum ServiceCategory: String, Sendable, CaseIterable, Codable {
  /// Publishes a reachable address for this server: ngrok, Cloudflare, zrok, LAN, dynamic DNS.
  case reverseProxy = "reverse-proxy"
  /// Delivers events outward: webhooks, ntfy, push.
  case eventSink = "event-sink"
  /// Sends or manipulates messages.
  case messaging
  /// Reads from or watches the message database.
  case messageSource = "message-source"
  /// Contacts, avatars, identity.
  case contacts
  /// The API surface itself: the HTTP server and the event socket.
  case networking
  /// Talks to the operating system: permissions, sleep, login items.
  case system
  /// Anything else a third party builds.
  case integration

  /// Whether only ONE service in this category may run at a time.
  ///
  /// This generalises what `proxy_service` already does by hand. Two reverse proxies would
  /// each publish a different `server_address` and fight over it — last writer wins, which
  /// presents as an address that changes on its own. Event sinks are the opposite: webhooks,
  /// ntfy and push are all expected to run together, and forcing a choice there would be
  /// removing a feature.
  public var isExclusive: Bool {
    switch self {
    case .reverseProxy: true
    case .eventSink, .messaging, .messageSource, .contacts, .networking, .system,
      .integration:
      false
    }
  }

  /// One line explaining what belongs in this group.
  ///
  /// Shown under the section header. Without it a category is a bare noun — "Event Sink"
  /// tells a user nothing, while "Where this server sends messages when they arrive" tells
  /// them whether the thing they are looking for is in here.
  public var summary: String {
    switch self {
    case .reverseProxy:
      "How clients reach this server. Only one can be active at a time."
    case .eventSink:
      "Where this server sends events as they happen. Any number can run together."
    case .messaging:
      "Sending messages and managing chats."
    case .messageSource:
      "Reading and watching the message database."
    case .contacts:
      "Turning phone numbers and addresses into names."
    case .networking:
      "The interfaces clients talk to. These are what the server IS — they cannot be "
        + "switched off."
    case .system:
      "How this server behaves on this Mac."
    case .integration:
      "Everything else."
    }
  }

  public var displayName: String {
    switch self {
    case .reverseProxy: "Connection Method"
    case .eventSink: "Notifications & Webhooks"
    case .messaging: "Messaging"
    case .messageSource: "Message Database"
    case .contacts: "Contacts"
    case .networking: "Networking"
    case .system: "System"
    case .integration: "Integrations"
    }
  }
}

// MARK: - Entitlements

/// Something a service asks permission to do, shown to the user before they agree.
///
/// **Operations, not secrets.** The most important rule here, and the one that is easy to get
/// backwards: there is no entitlement that hands over the server password, an ngrok key, or
/// any other credential. A service that needs to check a password gets
/// `.authenticateRequests` and asks the host to do the comparison, so a hostile or merely
/// compromised plugin never holds the secret at all. `readSettings` REFUSES secret keys at
/// validation time for the same reason.
///
/// Phrased for a person, because the whole point is that a user reads these and decides.
public enum Entitlement: Hashable, Sendable, Codable {
  /// Read specific settings belonging to someone else. Non-secret keys only.
  case readSettings(keys: Set<String>)
  /// Write specific settings belonging to someone else.
  ///
  /// Deliberately separate from reading: writing `server_address` redirects every client,
  /// which is a hijack, while reading it is harmless.
  case writeSettings(keys: Set<String>)
  /// Read message content from the database.
  case readMessages
  /// Send messages as the user.
  case sendMessages
  /// Read the address book.
  case readContacts
  /// Receive server events as they happen.
  case receiveEvents(names: Set<String>)
  /// Make outbound network connections to the named hosts.
  ///
  /// Hosts rather than a blanket flag: "connects to api.ngrok.com" is something a user can
  /// judge, "uses the network" is not.
  case network(hosts: Set<String>)
  /// Run a bundled or downloaded executable — the tunnels all need this.
  case spawnProcess
  /// Ask the host whether a presented credential is valid, WITHOUT being given the
  /// credential. See the note above; this is the shape every secret-adjacent need should
  /// take.
  case authenticateRequests
  /// Read and write files under the service's own storage directory. Its own only.
  case ownStorage

  /// One sentence, written for the person deciding.
  ///
  /// Uses raw storage keys for settings. Prefer `userFacingDescription(namingSettings:)` —
  /// this exists for callers with no way to resolve a name, and `db_poll_interval` is a
  /// column name, not something a person should have to decode.
  public var userFacingDescription: String {
    userFacingDescription(namingSettings: { $0 })
  }

  /// The same sentence, with settings named the way the settings screen names them.
  ///
  /// A closure rather than a lookup, because this module deliberately cannot see BBSettings:
  /// a manifest is pure data that may have arrived as JSON, and the registry of first-party
  /// settings is not something the manifest model should know about. The composition root
  /// owns both and can join them.
  ///
  /// The resolver returns the key itself for anything it does not recognise, so a plugin
  /// naming a setting that does not exist still produces a readable sentence.
  public func userFacingDescription(namingSettings resolve: (String) -> String) -> String {
    func named(_ keys: some Sequence<String>) -> String {
      keys.map(resolve).sorted().joined(separator: ", ")
    }

    return switch self {
    case .readSettings(let keys):
      "Read these server settings: \(named(keys))"
    case .writeSettings(let keys):
      "Change these server settings: \(named(keys))"
    case .readMessages:
      "Read your messages, including their contents"
    case .sendMessages:
      "Send messages as you"
    case .readContacts:
      "Read your contacts"
    case .receiveEvents(let names):
      names.isEmpty
        ? "Receive all server events"
        : "Receive these events: \(names.sorted().joined(separator: ", "))"
    case .network(let hosts):
      "Connect to \(hosts.sorted().joined(separator: ", "))"
    case .spawnProcess:
      "Run a program on this Mac"
    case .authenticateRequests:
      "Check whether a password is correct (without being able to read it)"
    case .ownStorage:
      "Store files of its own"
    }
  }

  /// Whether this is one a user should look twice at.
  ///
  /// Drives emphasis in the UI. Reading message content and sending as the user are the two
  /// that genuinely matter; everything else is ordinary.
  public var isSensitive: Bool {
    switch self {
    case .readMessages, .sendMessages, .readContacts, .writeSettings, .spawnProcess: true
    case .readSettings, .receiveEvents, .network, .authenticateRequests, .ownStorage: false
    }
  }
}

// MARK: - Configuration form

/// One element of a service's settings form.
///
/// Includes elements that carry no value — headers, notes, dividers — because a form is not
/// just a list of fields. The zrok setup needs a paragraph explaining what an account token is
/// and where to get one, and without display elements that explanation has to be smuggled into
/// a field's help text or left out.
public enum FormElement: Sendable, Codable, Equatable {
  case field(FieldDescriptor)
  /// A section title.
  case header(String)
  /// A section title whose contents start folded away.
  ///
  /// Everything `.header` is, plus the one thing it could not say: that what follows is
  /// tuning most people should never have to look at. Without it "Advanced" is just a word
  /// above a card that is always open, which labels the options rather than getting them out
  /// of the way — and a connection method's form is read by people whose only goal is to
  /// pick one and move on.
  ///
  /// A separate case rather than an associated flag on `.header`, because `FormElement` is
  /// `Codable` and part of the surface a third-party manifest is written against: adding a
  /// payload to an existing case breaks decoding of every manifest already published against
  /// the old shape, while adding a case leaves them decoding exactly as before.
  case collapsedHeader(String)
  /// Body text. A minimal Markdown subset (`**bold**`, `*italic*`, `[text](url)`) is
  /// rendered; anything else is shown literally rather than interpreted, so a manifest
  /// cannot inject arbitrary presentation.
  case paragraph(String)
  /// Secondary, smaller text — a caveat or a hint.
  case note(String)
  case divider
}

/// A single configurable value.
public struct FieldDescriptor: Sendable, Codable, Equatable {
  /// Unique within the service. The stored key is `<service id>.<key>`, assembled by the
  /// host — a manifest never supplies a fully-qualified key, which is what stops one
  /// service from declaring a field in another's namespace.
  public let key: String
  public let label: String
  public let help: String?
  public let kind: FieldKind
  /// Stored in the Keychain rather than the database, and redacted everywhere.
  public let isSecret: Bool
  /// The service will not start without it.
  public let isRequired: Bool
  /// Shown only when another field in the same form has a given value.
  ///
  /// Data rather than a closure so a third-party manifest can express it. zrok is the
  /// motivating case: the reserved name only makes sense once "reserve a tunnel" is on, and
  /// showing it unconditionally invites people to fill in a field that does nothing.
  public let visibleWhen: FieldCondition?

  /// Shown but NOT editable when another field has a given value.
  ///
  /// Distinct from `visibleWhen` on purpose. Hiding a field answers "what can I change?";
  /// greying one out answers "why can't I change this?", and the second question is the one
  /// a user asks when a control they remember has stopped working. Cloudflare's config-file
  /// mode is the motivating case: the tunnel's own `config.yml` owns those settings, and a
  /// field that vanished would look like a bug.
  public let disabledWhen: FieldCondition?
  /// Why the field is disabled, shown in its place.
  ///
  /// Required in practice: a greyed-out control with no explanation is worse than no
  /// control, because it looks broken rather than deliberate.
  public let disabledReason: String?

  public init(
    key: String,
    label: String,
    help: String? = nil,
    kind: FieldKind,
    isSecret: Bool = false,
    isRequired: Bool = false,
    visibleWhen: FieldCondition? = nil,
    disabledWhen: FieldCondition? = nil,
    disabledReason: String? = nil
  ) {
    self.key = key
    self.label = label
    self.help = help
    self.kind = kind
    self.isSecret = isSecret
    self.isRequired = isRequired
    self.visibleWhen = visibleWhen
    self.disabledWhen = disabledWhen
    self.disabledReason = disabledReason
  }
}

/// What kind of control a field is, and what values it accepts.
public enum FieldKind: Sendable, Codable, Equatable {
  case text(placeholder: String? = nil)
  /// Multi-line free text.
  case paragraph
  case number(range: ClosedRange<Int>? = nil)
  case decimal(range: ClosedRange<Double>? = nil)
  /// - Parameter default: what an install starts with, seeded on first run.
  ///
  ///   Needed because an unset flag reads as `false`, so before this a manifest could
  ///   express "off unless the user turns it on" and nothing else. A toggle whose safe
  ///   position is ON — anything that turns a debugging or data-collection feature OFF —
  ///   had no way to say so.
  case toggle(default: Bool = false)
  case date
  case select(options: [FieldOption])
  case multiSelect(options: [FieldOption])
  /// A filesystem path, with a chooser.
  case path
  case url
}

public struct FieldOption: Sendable, Codable, Equatable {
  public let value: String
  public let label: String
  public init(value: String, label: String) {
    self.value = value
    self.label = label
  }
}

/// "Show this field only when another one has this value."
public struct FieldCondition: Sendable, Codable, Equatable {
  public let field: String
  public let equals: String
  /// Further values that also reveal the field.
  ///
  /// A single `equals` could not describe a form with three modes where one input belongs to
  /// two of them — Cloudflare's public hostname is needed by a token tunnel and by an
  /// imported configuration, but not by a quick tunnel. The alternative was declaring the
  /// same input twice under two keys, which stores what the user typed in whichever copy was
  /// on screen and reads back the other one.
  public let orEquals: [String]

  public init(field: String, equals: String, orEquals: [String] = []) {
    self.field = field
    self.equals = equals
    self.orEquals = orEquals
  }

  /// Whether a sibling field's current value reveals this one.
  ///
  /// The single place the rule lives, so the form and the required-field check cannot come to
  /// different conclusions about whether the user was ever asked for something.
  public func isSatisfied(by value: String) -> Bool {
    value == equals || orEquals.contains(value)
  }

  // Decoded by hand purely so `orEquals` may be absent. A manifest written against the
  // one-value shape is still valid and still decodes; synthesised conformance would reject it
  // for a missing key.
  private enum CodingKeys: String, CodingKey {
    case field, equals, orEquals
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    field = try container.decode(String.self, forKey: .field)
    equals = try container.decode(String.self, forKey: .equals)
    orEquals = try container.decodeIfPresent([String].self, forKey: .orEquals) ?? []
  }
}

// MARK: - The manifest

public struct ServiceManifest: Sendable {

  public let id: ServiceIdentifier
  /// Shown in lists and section headers.
  public let name: String
  /// One line, shown next to the name.
  public let summary: String
  /// What it does, in a paragraph or two. Shown before a user enables it.
  public let details: String
  public let category: ServiceCategory
  /// The service's own version, for display and for update decisions.
  public let version: String
  /// Services that must be running first. The registry topologically sorts these and
  /// refuses a cycle at launch.
  public let dependencies: [ServiceIdentifier]
  /// Everything it may do beyond its own namespace. Deny by default: an entitlement that is
  /// not listed is not available, and asking at runtime fails rather than prompting.
  public let entitlements: [Entitlement]
  /// Its configuration form. Keys are relative to the service's own namespace.
  public let settings: [FormElement]
  /// External programs this needs, declared as data so a plugin can need one too.
  ///
  /// The host installs, verifies, version-checks and updates whatever is listed here; the
  /// service asks for a path and gets one. See `ToolRequirement` for why this is a
  /// declaration rather than a downloader compiled into each service.
  public let tools: [ManagedToolDescriptor]
  /// How to bring stored settings forward when `version` moves.
  ///
  /// Declarative, like everything else here — see `ServiceMigration`. Without them a service
  /// that renames a field on update silently loses whatever the user had configured: the old
  /// key sits in the database and the new one reads as unset.
  public let migrations: [FieldMigration]
  /// Seeded services ship enabled and may hold core entitlements. Third-party plugins are
  /// neither, which is the only place the two are treated differently.
  public let isBuiltIn: Bool
  /// Whether this belongs on the Integrations screen at all.
  ///
  /// Some services exist only to carry out a setting — Keep Awake holds a power assertion
  /// when `auto_caffeinate` is on, Start at Login registers a login item when
  /// `auto_start_method` is set. Listing them as integrations gave each a SECOND switch that
  /// did not agree with the first, and Permissions is worse: it tracks what macOS has
  /// granted, so "disable" is not a thing it can meaningfully do.
  ///
  /// They are still services — they have a lifecycle and dependencies — they are just not
  /// things a user installs, enables or configures. The setting is the control.
  public let isUserManageable: Bool
  /// Whether this can run at all on this host — a plugin built against a newer host API is
  /// refused rather than crashed into.
  public let minimumHostVersion: Int

  public init(
    id: ServiceIdentifier,
    name: String,
    summary: String,
    details: String = "",
    category: ServiceCategory,
    version: String = "1.0.0",
    dependencies: [ServiceIdentifier] = [],
    entitlements: [Entitlement] = [],
    settings: [FormElement] = [],
    tools: [ManagedToolDescriptor] = [],
    migrations: [FieldMigration] = [],
    isBuiltIn: Bool = true,
    isUserManageable: Bool = true,
    minimumHostVersion: Int = ServiceManifest.hostAPIVersion
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.details = details
    self.category = category
    self.version = version
    self.dependencies = dependencies
    self.entitlements = entitlements
    self.settings = settings
    self.tools = tools
    self.migrations = migrations
    self.isBuiltIn = isBuiltIn
    self.isUserManageable = isUserManageable
    self.minimumHostVersion = minimumHostVersion
  }

  /// A minimal manifest, for a service whose identity is all that matters.
  ///
  /// Used by tests and by services with nothing to declare. Not a shortcut around the model
  /// — the result is a real manifest that the validator will check like any other; it just
  /// spares a caller from writing a description for a double called "recording".
  public static func minimal(
    id: String,
    dependencies: [ServiceIdentifier] = [],
    category: ServiceCategory = .system
  ) -> ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier(id),
      name: id,
      summary: "\(id) service.",
      category: category,
      dependencies: dependencies
    )
  }

  /// The host's plugin API version.
  ///
  /// Bumped when a change would break a plugin compiled against the old shape. A plugin
  /// declaring a higher `minimumHostVersion` than this is refused at load with a message
  /// naming the version it wants, rather than being started and failing somewhere strange.
  public static let hostAPIVersion = 1

  /// Every value field, flattened out of the form's display elements.
  public var fields: [FieldDescriptor] {
    settings.compactMap { if case .field(let field) = $0 { return field } else { return nil } }
  }

  /// The tool with this id, if this service declares it.
  public func tool(_ id: String) -> ManagedToolDescriptor? {
    tools.first { $0.id == id }
  }

  /// The fully-qualified storage key for one of this service's own fields.
  public func storageKey(for field: String) -> String {
    "\(id.settingsNamespace)\(field)"
  }
}
