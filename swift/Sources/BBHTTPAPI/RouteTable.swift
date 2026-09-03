//  RouteTable
//  The complete /api/v1 surface, declared once.
//
//  This is a transcription of httpRoutes.ts, and it is deliberately a transcription: the
//  parity harness diffs this table against the Node server's registered routes, so a route
//  that is "obviously redundant" here is a route a client is calling.
//
//  Three things about it are load-bearing and look like mistakes if you don't know:
//
//    1. ORDER MATTERS. Routes register in declaration order and the first match wins, so a
//       `:guid` catch-all placed before a literal sibling swallows it. `PUT /contact/:id`
//       must precede `GET /contact/external/:externalId`, and every group's `:guid` routes
//       come last. Reordering this file for tidiness breaks routing.
//
//    2. DUPLICATE HANDLERS ARE INTENTIONAL. `POST :guid/participant` and
//       `POST :guid/participant/add` both add a participant; `PUT /contact` and
//       `PUT /contact/:id` are both update. Different client versions call different ones.
//
//    3. PER-ROUTE TIMEOUTS DIFFER BY ORDERS OF MAGNITUDE. Attachment download gets 30
//       minutes, force-download 60, update install 30, and the macOS group 30 seconds.
//       Applying one default would break large transfers on slow tunnels.
//
//  See `.claude/docs/api.md`.

import BBAuth
import Foundation

// MARK: - Route model

public enum HTTPMethod: String, Sendable, CaseIterable {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case delete = "DELETE"
}

/// Extra middleware a route needs beyond its group's chain.
public struct RouteRequirements: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Requires the Private API helper to be connected. Fails with `IMessageError` (HTTP
  /// 500) and the helper-unavailable message — not a 503, which would be more correct.
  public static let privateAPI = RouteRequirements(rawValue: 1 << 0)

  /// Skips authentication. Only the UI index route.
  public static let unauthenticated = RouteRequirements(rawValue: 1 << 1)

  /// Authenticates IF a credential is offered, and proceeds either way.
  ///
  /// Exists for enrollment, which is reachable by an unenrolled caller by necessity and
  /// accepts either the server password or a one-time code. Marking it `.unauthenticated`
  /// made the password half unreachable: the router only populates `principal` when it
  /// authenticates, so `auth.register` — which decides between the two paths by asking
  /// whether a principal exists — saw nil every time and demanded a code. Nothing issues
  /// codes (`issueEnrollmentCode` has no route and no UI), so the whole token-auth surface
  /// was unreachable: no credentials could be minted, and `token`, `rotate` and `revoke`
  /// all need them.
  ///
  /// A failed credential is NOT an error here. Someone enrolling with a code has no
  /// password to send, and rejecting them for that would close the other door.
  public static let optionalAuthentication = RouteRequirements(rawValue: 1 << 2)
}

public struct RouteDefinition: Sendable {
  public let method: HTTPMethod
  /// Path relative to the group prefix, e.g. `:guid/download`.
  public let path: String
  public let handlerID: HandlerID
  public let requirements: RouteRequirements
  /// Declared per route so scope enforcement is metadata rather than a second middleware
  /// pass. Unused while `auth_mode` is `password`, where the principal holds every scope.
  public let scope: Scope
  public let requestTimeout: Duration?
  public let responseTimeout: Duration?

  init(
    _ method: HTTPMethod,
    _ path: String,
    _ handlerID: HandlerID,
    scope: Scope = .messagesRead,
    requires requirements: RouteRequirements = [],
    requestTimeout: Duration? = nil,
    responseTimeout: Duration? = nil
  ) {
    self.method = method
    self.path = path
    self.handlerID = handlerID
    self.requirements = requirements
    self.scope = scope
    self.requestTimeout = requestTimeout
    self.responseTimeout = responseTimeout
  }
}

public struct RouteGroup: Sendable {
  public let name: String
  /// Empty for the General group, whose routes sit directly under `/api/v1`.
  public let prefix: String
  public let requirements: RouteRequirements
  public let responseTimeout: Duration?
  /// Mounts at the server root instead of under `/api/v<n>`.
  ///
  /// True for exactly one group — the landing page, which is Node's separate
  /// `HttpRoutes.ui` definition rather than part of the versioned API. Keeping it a flag on
  /// the group rather than a special case in `buildRouter` means the path a request will
  /// actually hit is still derivable from the table alone, which is what
  /// `mountedRoutes()` and the parity extractor both depend on.
  public let mountsAtRoot: Bool
  /// Which API version this group mounts under.
  ///
  /// **v1 is the Node server's surface and nothing else.** Every route in it exists because
  /// the Electron server had it, which is what lets the parity harness diff the two tables
  /// as equals and what lets a client upgrade without noticing. A bug FIX belongs in v1 — if
  /// this server answers a v1 route differently from the reference, one of them is wrong.
  /// New capability does not, however small and however additive it looks.
  ///
  /// **v2 is everything this server does that the Node server never did.** Its routes are
  /// still individually gated — by `additive_endpoints`, by a feature flag, by `auth_mode` —
  /// so the version is not a switch that turns them all on. It is where a client goes
  /// looking for what is new, and it keeps that question separable from "is this server
  /// still compatible".
  public let apiVersion: Int
  public let routes: [RouteDefinition]

  init(
    _ name: String,
    prefix: String = "",
    requires requirements: RouteRequirements = [],
    responseTimeout: Duration? = nil,
    mountsAtRoot: Bool = false,
    apiVersion: Int = 1,
    routes: [RouteDefinition]
  ) {
    self.name = name
    self.prefix = prefix
    self.requirements = requirements
    self.responseTimeout = responseTimeout
    self.mountsAtRoot = mountsAtRoot
    self.apiVersion = apiVersion
    self.routes = routes
  }
}

/// Identifies a handler without importing the controllers here, which keeps the table a
/// pure description that a test can read without standing up the server.
///
/// Deliberately NOT `ExpressibleByStringLiteral`. Every identifier is declared once in
/// `HandlerIDs.swift`, so the table and the controller that serves it reference the same
/// constant and a typo is a compile error rather than a route with no handler. The
/// initialiser stays public because the raw form is still needed to read one back — from a
/// recorded fixture, or from the parity harness — but writing a new identifier means adding
/// it there.
public struct HandlerID: Hashable, Sendable {
  public let rawValue: String
  public init(_ value: String) { self.rawValue = value }
}

// MARK: - The table

public enum RouteTable {

  /// The version the Node-compatible surface mounts under. It has been 1 since the
  /// beginning and does not move: v1 IS the Node server's API, and bumping it would break
  /// every client at once. New surface goes to `latestVersion` instead.
  public static let version = 1

  /// Where new, non-Node surface mounts. See `RouteGroup.apiVersion`.
  public static let latestVersion = 2

  public static let defaultRequestTimeout = Duration.seconds(60)
  public static let defaultResponseTimeout = Duration.seconds(300)

  /// The `/api/v1` surface, and ONLY that.
  ///
  /// This array is what the parity fixture is diffed against, in both directions, so
  /// nothing may be added to it that the Node server's `HttpRoutes.api` definition does not
  /// have. Anything else belongs in `AdditiveRoutes` or in `alwaysMounted` below.
  public static let groups: [RouteGroup] = [
    general, macOS, iCloud, server, fcm, attachment, chat, message,
    handle, faceTime, contact, backup, webhook,
  ]

  /// What every server mounts, whatever its settings.
  ///
  /// `groups` plus the landing page. The two are separate because they answer different
  /// questions: `groups` is "what does the versioned API expose", which the parity harness
  /// owns, and this is "what does the router mount", which is what the server actually
  /// serves. Node draws the same line — `HttpRoutes.api` and `HttpRoutes.ui` are two
  /// definitions registered onto one router.
  public static let alwaysMounted: [RouteGroup] = groups + [landing]

  /// Every route as a mountable path, in registration order.
  ///
  /// `/api/v1` + group prefix + route path, with empty components dropped — which is how
  /// `GET /api/v1/contact` (empty route path) and `GET /api/v1/ping` (empty group prefix)
  /// both come out right.
  public static func mountedRoutes() -> [(path: String, group: RouteGroup, route: RouteDefinition)]
  {
    groups.flatMap { group in
      group.routes.map { (path(of: $0, in: group), group, $0) }
    }
  }

  /// Where a route mounts. The one derivation, so the router and the parity tests cannot
  /// disagree about it.
  public static func path(of route: RouteDefinition, in group: RouteGroup) -> String {
    let versionComponents = group.mountsAtRoot ? [] : ["api", "v\(group.apiVersion)"]
    let components = (versionComponents + [group.prefix, route.path])
      .filter { !$0.isEmpty }
    // A root-mounted group with an empty prefix and an empty path is `/` itself, which
    // joins to the empty string — hence the explicit floor rather than "/" + "".
    return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
  }

  /// `GET /` — the landing page.
  ///
  /// NOT in `groups`, and that is deliberate on both counts. It is not additive surface
  /// either: the Node server has always served it, from a SEPARATE `HttpRoutes.ui`
  /// definition mounted at the root rather than from the versioned API table
  /// (`httpRoutes.ts:735-751`). `Tools/route-table/extract.py` scans only the `api`
  /// definition, so this route is outside the parity set by construction — putting it in
  /// `groups` would fail the "adds nothing to the Node route set" test for a route the Node
  /// server does in fact serve.
  ///
  /// Unauthenticated, matching Node's `unprotected` middleware. It reveals nothing: a
  /// static page, or whatever file the operator pointed `landing_page_path` at. This is
  /// also the route that answers "is my tunnel actually up?" from a browser, which is why
  /// leaving it 404ing was worse than it looked — the first thing a user does after
  /// configuring cloudflared is paste the URL into a browser.
  public static let landing = RouteGroup(
    "Index", mountsAtRoot: true,
    routes: [
      .init(.get, "", .uiIndex, requires: .unauthenticated)
    ]
  )

  // MARK: General

  static let general = RouteGroup(
    "General",
    routes: [
      .init(.get, "ping", .generalPing)
    ])

  // MARK: macOS

  static let macOS = RouteGroup(
    "macOS", prefix: "mac", responseTimeout: .seconds(30),
    routes: [
      .init(.post, "lock", .macLock, scope: .serverAdmin),
      .init(.post, "imessage/restart", .macRestartMessages, scope: .serverAdmin),
    ])

  // MARK: iCloud
  //
  // FindMy lives under this prefix rather than its own. `findmy/devices` works without the
  // helper (it reads a cache file); `findmy/friends` does not.

  static let iCloud = RouteGroup(
    "iCloud", prefix: "icloud",
    routes: [
      .init(.get, "account", .icloudAccountInfo, requires: .privateAPI),
      .init(
        .post, "account/alias", .icloudChangeAlias, scope: .serverAdmin, requires: .privateAPI),
      .init(.get, "contact", .icloudContactCard, requires: .privateAPI),
      .init(.get, "findmy/devices", .findmyDevices),
      .init(.post, "findmy/devices/refresh", .findmyRefreshDevices),
      .init(.get, "findmy/friends", .findmyFriends, requires: .privateAPI),
      .init(.post, "findmy/friends/refresh", .findmyRefreshFriends, requires: .privateAPI),
    ])

  // MARK: Server

  static let server = RouteGroup(
    "Server", prefix: "server",
    routes: [
      .init(.get, "info", .serverInfo),
      .init(.get, "logs", .serverLogs, scope: .serverAdmin),

      // Both restarts are GET. Non-idempotent verbs behind GET is not what we would
      // choose, but clients issue them as GET.
      .init(.get, "restart/soft", .serverRestartServices, scope: .serverAdmin),
      .init(.get, "restart/hard", .serverRestartAll, scope: .serverAdmin),

      .init(.get, "update/check", .serverCheckUpdate, scope: .serverAdmin),
      .init(
        .post, "update/install", .serverInstallUpdate,
        scope: .serverAdmin, responseTimeout: .seconds(1800)),

      .init(.get, "alert", .serverAlerts),
      .init(.post, "alert/read", .serverMarkAlertRead),

      // The report's brute-force target: unauthenticated guessing was cheap here because
      // it is a plain GET with a small response. Failure-only rate limiting covers it now.
      .init(.get, "statistics/totals", .serverStatTotals),
      .init(.get, "statistics/media", .serverStatMedia),
      .init(.get, "statistics/media/chat", .serverStatMediaByChat),
    ])

  // MARK: FCM

  static let fcm = RouteGroup(
    "FCM", prefix: "fcm",
    routes: [
      .init(.post, "device", .fcmRegisterDevice, scope: .serverAdmin),
      // Synthesizes `oauth_client[]` when Google omits it. Clients break without that key.
      .init(.get, "client", .fcmClientConfig, scope: .serverAdmin),
    ])

  // MARK: Attachment

  static let attachment = RouteGroup(
    "Attachment", prefix: "attachment",
    routes: [
      .init(.get, "count", .attachmentCount),
      .init(.post, "upload", .attachmentUpload, scope: .messagesWrite, requires: .privateAPI),

      .init(
        .get, ":guid/download", .attachmentDownload,
        scope: .attachmentsRead, responseTimeout: .seconds(1800)),
      .init(
        .get, ":guid/download/force", .attachmentForceDownload,
        scope: .attachmentsRead, requires: .privateAPI, responseTimeout: .seconds(3600)),
      .init(.get, ":guid/blurhash", .attachmentBlurhash, scope: .attachmentsRead),
      .init(
        .get, ":guid/live", .attachmentDownloadLive,
        scope: .attachmentsRead, responseTimeout: .seconds(1800)),
      .init(.get, ":guid", .attachmentFind, scope: .attachmentsRead),
    ])

  // MARK: Chat

  static let chat = RouteGroup(
    "Chat", prefix: "chat",
    routes: [
      // Creating a chat works without the helper, but only PARTLY, which is why this is
      // not gated on `.privateAPI`.
      //
      // One-to-one: AppleScript, by sending to the participant. Group: the user-installed
      // Shortcut, because AppleScript has had no group path since Big Sur. A group request
      // on a server with neither refuses with an explanation naming the setting that fixes
      // it — see `ChatInterface.create`. Gating the whole route would take away the
      // one-to-one case that has always worked here.
      .init(.post, "new", .chatCreate, scope: .chatsWrite),
      .init(.get, "count", .chatCount),
      .init(.post, "query", .chatQuery),

      .init(.get, ":guid/message", .chatMessages),
      .init(.get, ":guid/share/contact/status", .chatShouldShareContact, requires: .privateAPI),
      .init(
        .post, ":guid/share/contact", .chatShareContact,
        scope: .chatsWrite, requires: .privateAPI),
      .init(.post, ":guid/read", .chatMarkRead, scope: .chatsWrite, requires: .privateAPI),
      .init(.post, ":guid/unread", .chatMarkUnread, scope: .chatsWrite, requires: .privateAPI),
      .init(.post, ":guid/leave", .chatLeave, scope: .chatsWrite, requires: .privateAPI),

      // Four routes, two handlers. POST/DELETE :guid/participant is the older form and
      // POST :guid/participant/{add,remove} the newer; both ship.
      .init(
        .post, ":guid/participant", .chatAddParticipant,
        scope: .chatsWrite, requires: .privateAPI),
      .init(
        .delete, ":guid/participant", .chatRemoveParticipant,
        scope: .chatsWrite, requires: .privateAPI),
      .init(
        .post, ":guid/participant/add", .chatAddParticipant,
        scope: .chatsWrite, requires: .privateAPI),
      .init(
        .post, ":guid/participant/remove", .chatRemoveParticipant,
        scope: .chatsWrite, requires: .privateAPI),

      .init(.post, ":guid/typing", .chatStartTyping, scope: .chatsWrite, requires: .privateAPI),
      .init(.delete, ":guid/typing", .chatStopTyping, scope: .chatsWrite, requires: .privateAPI),

      .init(.post, ":guid/icon", .chatSetGroupIcon, scope: .chatsWrite, requires: .privateAPI),
      .init(
        .delete, ":guid/icon", .chatRemoveGroupIcon, scope: .chatsWrite, requires: .privateAPI),
      // GET icon needs no helper — it reads the attachment off disk.
      .init(.get, ":guid/icon", .chatGroupIcon, scope: .attachmentsRead),

      // Two path params. Must precede the bare `:guid` routes below.
      .init(
        .delete, ":guid/:messageGuid", .chatDeleteMessage,
        scope: .chatsWrite, requires: .privateAPI),

      .init(.put, ":guid", .chatUpdate, scope: .chatsWrite, requires: .privateAPI),
      .init(.get, ":guid", .chatFind),
      .init(.delete, ":guid", .chatDelete, scope: .chatsWrite, requires: .privateAPI),
    ])

  // MARK: Message

  static let message = RouteGroup(
    "Message", prefix: "message",
    routes: [
      // No .privateAPI on the send routes: AppleScript is the fallback and it is a
      // supported configuration, not a degraded one.
      .init(.post, "text", .messageSendText, scope: .messagesWrite),
      .init(.post, "attachment", .messageSendAttachment, scope: .messagesWrite),
      .init(.post, "attachment/chunk", .messageSendAttachmentChunk, scope: .messagesWrite),
      .init(.post, "multipart", .messageSendMultipart, scope: .messagesWrite),

      .init(.post, "react", .messageReact, scope: .messagesWrite, requires: .privateAPI),

      .init(.get, "count", .messageCount),
      .init(.get, "count/updated", .messageCountUpdated),
      .init(.get, "count/me", .messageSentCount),
      .init(.post, "query", .messageQuery),

      // Scheduled messages live under /message even though they are their own subsystem.
      .init(.get, "schedule", .scheduleList),
      .init(.post, "schedule", .scheduleCreate, scope: .messagesWrite),
      .init(.get, "schedule/:id", .scheduleFind),
      .init(.put, "schedule/:id", .scheduleUpdate, scope: .messagesWrite),
      .init(.delete, "schedule/:id", .scheduleDelete, scope: .messagesWrite),

      .init(.get, ":guid", .messageFind),
      // Edit and unsend check the helper inside the handler rather than via middleware,
      // because they also gate on macOS version and want a different message.
      .init(.post, ":guid/edit", .messageEdit, scope: .messagesWrite),
      .init(.post, ":guid/unsend", .messageUnsend, scope: .messagesWrite),
      .init(.post, ":guid/notify", .messageNotify, scope: .messagesWrite, requires: .privateAPI),
      .init(
        .get, ":guid/embedded-media", .messageEmbeddedMedia,
        scope: .attachmentsRead, requires: .privateAPI),
    ])

  // MARK: Handle

  static let handle = RouteGroup(
    "Handle", prefix: "handle",
    routes: [
      .init(.get, "count", .handleCount),
      .init(.post, "query", .handleQuery),
      .init(.get, "availability/imessage", .handleIMessageAvailability, requires: .privateAPI),
      // FaceTime availability does not need the helper; iMessage availability does.
      .init(.get, "availability/facetime", .handleFaceTimeAvailability),
      .init(.get, ":guid", .handleFind),
      .init(.get, ":guid/focus", .handleFocusStatus),
    ])

  // MARK: FaceTime
  //
  // The whole group requires the helper, declared once at group level.

  static let faceTime = RouteGroup(
    "FaceTime", prefix: "facetime", requires: .privateAPI,
    routes: [
      .init(.post, "session", .facetimeNewSession, scope: .chatsWrite),
      .init(.post, "answer/:call_uuid", .facetimeAnswer, scope: .chatsWrite),
      // Returns 201 "No Data", not 200. Asserted by the parity harness.
      .init(.post, "leave/:call_uuid", .facetimeLeave, scope: .chatsWrite),
    ])

  // MARK: Contact
  //
  // The ordering trap. `PUT :id` before `GET external/:externalId` is what the Node table
  // does, and `DELETE :id` before `DELETE ""`.

  static let contact = RouteGroup(
    "Contact", prefix: "contact",
    routes: [
      .init(.get, "", .contactList),
      .init(.post, "", .contactCreate, scope: .serverAdmin),
      .init(.put, "", .contactUpdate, scope: .serverAdmin),
      .init(.put, ":id", .contactUpdate, scope: .serverAdmin),
      .init(.get, "external/:externalId", .contactFindByExternalID),
      .init(.delete, ":id", .contactDelete, scope: .serverAdmin),
      .init(.delete, "", .contactDelete, scope: .serverAdmin),
      .init(.post, "query", .contactQuery),
      .init(.post, "import/vcf", .contactImportVCF, scope: .serverAdmin),
    ])

  // MARK: Backup

  static let backup = RouteGroup(
    "Backup", prefix: "backup",
    routes: [
      .init(.get, "theme", .backupGetTheme),
      .init(.post, "theme", .backupCreateTheme, scope: .serverAdmin),
      .init(.delete, "theme", .backupDeleteTheme, scope: .serverAdmin),
      .init(.get, "settings", .backupGetSettings),
      .init(.post, "settings", .backupCreateSettings, scope: .serverAdmin),
      .init(.delete, "settings", .backupDeleteSettings, scope: .serverAdmin),
    ])

  // MARK: Webhooks

  static let webhook = RouteGroup(
    "Webhooks", prefix: "webhook",
    routes: [
      .init(.get, "", .webhookList, scope: .serverAdmin),
      .init(.post, "", .webhookCreate, scope: .serverAdmin),
      .init(.delete, ":id", .webhookDelete, scope: .serverAdmin),
    ])
}

// MARK: - Additive routes

/// Routes that do not exist on the Node server.
///
/// Kept apart from `RouteTable.groups` for one reason: the parity harness diffs that table
/// against the Node route list and fails on any addition. Anything here has to be registered
/// deliberately, which is what stops "additive" from drifting into "changed".
public enum AdditiveRoutes {

  /// Access-control administration, and **`#if DEBUG` — never in a shipped binary.**
  ///
  /// These edit the rules that decide who may talk to the server: unblock an address, add a
  /// CIDR to the permanent allowlist, clear the blocklist entirely. Reaching them requires
  /// authenticating first, which sounds like enough and is not. The blocklist exists to stop
  /// somebody who is guessing the password, and the credential is a single shared secret
  /// with no per-device identity — so anyone who has it, including whoever guessed it, can
  /// switch off the thing that was slowing them down and allowlist themselves permanently.
  /// A remote API for that turns one compromised password into durable access.
  ///
  /// `#if DEBUG` rather than a setting, for the reason the FaceTime diagnostics use it: a
  /// runtime switch can be flipped on a production server, and `server:admin` is exactly the
  /// scope an attacker already holds. The guarantee has to be "not in the binary".
  ///
  /// **Nothing is lost.** Access control is administered from the Security page in the app,
  /// where the operator is at the machine, and `--clear-blocklist` recovers a total lockout
  /// from the command line without even building the server. Neither is reachable remotely,
  /// which is the point.
  public static var security: RouteGroup {
    RouteGroup(
      "Security", prefix: "server/security", apiVersion: RouteTable.latestVersion,
      routes: securityRoutes
    )
  }

  static var securityRoutes: [RouteDefinition] {
    #if DEBUG
      return [
        .init(.get, "blocklist", .securityListBlocked, scope: .serverAdmin),
        .init(.delete, "blocklist", .securityClearBlocked, scope: .serverAdmin),
        .init(.delete, "blocklist/:id", .securityUnblock, scope: .serverAdmin),
        .init(.get, "allowlist", .securityListAllowed, scope: .serverAdmin),
        .init(.post, "allowlist", .securityAllow, scope: .serverAdmin),
        .init(.delete, "allowlist/:id", .securityDisallow, scope: .serverAdmin),
        .init(.get, "failures", .securityRecentFailures, scope: .serverAdmin),
      ]
    #else
      return []
    #endif
  }

  /// Alerts, with everything an alert actually carries — structured actions, severity and
  /// occurrence count.
  ///
  /// The v1 row is six flat keys, and it stays that way — it is the reference's `alert`
  /// table and clients read it. This is where the title and body stay separate, the real
  /// five-value severity survives, and the diagnostics, remedy actions and occurrence count
  /// have somewhere to go.
  ///
  /// `read` is duplicated here rather than shared with v1 so a v2 client never has to fall
  /// back to a v1 path mid-flow. Both take the same integer ids, because both versions
  /// describe the same alerts.
  public static let alerts = RouteGroup(
    "Alerts", prefix: "server/alert", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.get, "", .serverAlertsV2),
      .init(.post, "read", .serverMarkAlertReadV2),
    ]
  )

  /// Streams a contact avatar with an ETag instead of base64-in-JSON. The inline
  /// `avatar` field stays exactly as it is; this is a second way to get the same image.
  public static let contactAvatar = RouteGroup(
    "Contact Avatar", prefix: "contact", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.get, ":id/avatar", .contactAvatar)
    ])

  /// The shared contact card, with everything the helper actually reports.
  ///
  /// v1's `icloud/contact` is frozen at the reference's two keys — `name` and `avatar` —
  /// and `Fixtures/http/get_api_v1_icloud_contact-5baa61-200.json` is what holds it there.
  /// `NicknameInfo` carries more than that: which handle the card belongs to, and whether a
  /// card was shared at all, which a client cannot otherwise distinguish from a person who
  /// shared one containing nothing.
  ///
  /// Additive rather than a change to v1, for the standing reason: an extra key in a v1
  /// response fails the parity diff exactly like a missing one.
  public static let contactCard = RouteGroup(
    "Contact Card", prefix: "icloud", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.get, "contact", .icloudContactCardV2, requires: .privateAPI)
    ])

  /// Editing a registered webhook. The v1 surface could only create and delete one
  /// over HTTP — changing an endpoint's URL or its event subscriptions was an Electron IPC
  /// call with no route behind it — so this is additive by definition and a default table
  /// carrying it would no longer match.
  ///
  /// The app does not need it: it holds `AdminInterface` in process and calls
  /// `updateWebhook` directly. It is here so a client can do what the settings window can,
  /// which is the standing rule for anything the UI can reach.
  public static let webhookEditing = RouteGroup(
    "Webhook Editing", prefix: "webhook", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.put, ":id", .webhookUpdate, scope: .serverAdmin)
    ]
  )

  /// Batch hydration for `reference-v2` (`docs/EVENTS.md` § "`reference-v2`"). Registered
  /// only when a non-legacy codec is enabled — a client on `legacy-v1` never needs it, and
  /// an endpoint nobody calls is still an endpoint an attacker can.
  public static let hydration = RouteGroup(
    "Hydration", prefix: "message", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.post, "hydrate", .messageHydrate)
    ])

  /// Apple's own "Send Later", which the Node server never had — its `/message/schedule`
  /// routes are this SERVER's timer, which holds the message and sends it when the Mac is
  /// awake and the server is running. This is the other thing: the message goes to Apple
  /// scheduled, and iMessage delivers it whether or not this Mac is on.
  ///
  /// Under `message/` with the literal ahead of any `:guid`, per the ordering rule.
  public static let sendLater = RouteGroup(
    "Send Later", prefix: "message", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.post, "send-later", .messageSendLater, scope: .messagesWrite, requires: .privateAPI),
      .init(
        .delete, "send-later/:guid", .messageCancelScheduled, scope: .messagesWrite,
        requires: .privateAPI),
    ])

  /// Placing a sticker on a message.  /// Placing a sticker on a message. The Node server never sent one — its helper had no
  /// action for it and its route table has no path — so this is additive by definition.
  ///
  /// Under `message/` beside `react`, because that is what it is: a reaction whose payload
  /// is a file. The body is the reaction route's (`chatGuid`, `selectedMessageGuid`,
  /// `partIndex`) plus the attachment route's `filePath` — a path an earlier
  /// `attachment/upload` answered with, never bytes — and an optional placement
  /// (`xScalar`, `yScalar`, `scale`, `rotation`, `parentPreviewWidth`) in the coordinate
  /// space `StickerPlacement` documents. Answers with the sticker's own message row, as
  /// `react` answers with the tapback's.
  public static let stickers = RouteGroup(
    "Stickers", prefix: "message", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.post, "sticker", .messageSendSticker, scope: .messagesWrite, requires: .privateAPI)
    ])

  /// Pinning a conversation. The helper has always been able to do this and the v1 surface
  /// server never exposed it, so it is additive by definition — a default table that
  /// carried it would no longer match.
  public static let chatPinning = RouteGroup(
    "Chat Pinning", prefix: "chat", apiVersion: RouteTable.latestVersion,
    routes: [
      // LITERAL BEFORE PARAMETER. `pin` has to register ahead of `:guid/pin` or the
      // catch-all swallows it and a GET arrives with `guid = "pin"`. This is the ordering
      // rule the whole table depends on, and it bites hardest where a literal and a
      // parameter share a prefix.
      //
      // Reads the pinned list in DISPLAY ORDER, which is what makes it usable for syncing
      // pins between devices: pins render in this sequence, so a client that treats the
      // response as a set reshuffles the user's arrangement every time it syncs.
      .init(.get, "pin", .chatPinned, requires: .privateAPI),
      .init(.post, ":guid/pin", .chatPin, scope: .chatsWrite, requires: .privateAPI),
      .init(.delete, ":guid/pin", .chatUnpin, scope: .chatsWrite, requires: .privateAPI),
    ])

  /// Conversation controls the Node server never exposed: wallpaper, mute, filtering,
  /// clearing history. See `docs/CHAT_CONTROLS_PLAN.md`.
  ///
  /// Additive by definition — none of these paths exist in the reference table, so a
  /// default-configured server must not carry them.
  ///
  /// **The reads are not all Private-API reads.** `GET :guid/background` serves bytes
  /// Messages already cached on disk, exactly like `chat.groupIcon` in the v1 group, so it
  /// carries `attachments:read` and no `.privateAPI` requirement. Requiring the helper for
  /// it would make a conversation's wallpaper unreadable on a server that has the database
  /// and not SIP disabled, which is the common configuration.
  public static let chatControls = RouteGroup(
    "Chat Controls", prefix: "chat", apiVersion: RouteTable.latestVersion,
    routes: [
      // MORE SPECIFIC FIRST. `:guid/background/info` and `:guid/background` differ in
      // segment count so the router separates them either way — declaring the longer
      // one first keeps the group readable under the table's own rule rather than
      // relying on that.
      .init(.get, ":guid/background/info", .chatBackgroundInfo, scope: .attachmentsRead),
      // A download, not a change to the conversation — so `attachments:read` like the
      // rest of the background group, and the helper because only imagent can fetch it.
      .init(
        .post, ":guid/background/fetch", .chatFetchBackground,
        scope: .attachmentsRead, requires: .privateAPI),
      .init(.get, ":guid/background", .chatBackground, scope: .attachmentsRead),

      // Mute. The read carries the default scope, matching `chat.pinned`; the writes
      // carry `chats:write` like every other chat write.
      .init(.get, ":guid/mute", .chatMuteState, requires: .privateAPI),
      .init(.post, ":guid/mute", .chatMute, scope: .chatsWrite, requires: .privateAPI),
      .init(.delete, ":guid/mute", .chatUnmute, scope: .chatsWrite, requires: .privateAPI),

      // Filtering. `known`, `spam` and `junk` are three doors into the same state, and
      // `filter` is the read plus the way back out — including recovery from Junk.
      .init(.get, ":guid/filter", .chatFilterState, requires: .privateAPI),
      .init(
        .post, ":guid/filter", .chatSetFilter,
        scope: .chatsWrite, requires: .privateAPI),
      .init(
        .post, ":guid/known", .chatMarkKnown,
        scope: .chatsWrite, requires: .privateAPI),
      .init(
        .post, ":guid/spam", .chatMarkSpam,
        scope: .chatsWrite, requires: .privateAPI),
      .init(
        .post, ":guid/junk", .chatReportJunk,
        scope: .chatsWrite, requires: .privateAPI),

      // Empties a conversation, keeping the conversation. Note where this ISN'T: the
      // v1 chat group has `DELETE :guid/:messageGuid`, which would match this path and
      // try to delete a message whose GUID is the literal string "messages".
      .init(
        .delete, ":guid/messages", .chatClearHistory,
        scope: .chatsWrite, requires: .privateAPI),
    ]
  )

  /// FindMy device and location routes beyond the v1 surface.
  ///
  /// Under the same `icloud/findmy` prefix as the four inherited routes, which keeps a
  /// client's FindMy calls in one place — but declared here, because adding a path to
  /// `RouteTable.iCloud` would break the parity diff. Gated on `Features.findMy`.
  ///
  /// Addresses travel in the BODY rather than as path segments, deliberately. A FindMy
  /// handle is a phone number or an email — `+12025550143`, `someone@example.com` — and
  /// both need percent-encoding that clients get wrong in both directions. A body has no
  /// such trap.
  public static let findMy = RouteGroup(
    "Find My", prefix: "icloud/findmy", apiVersion: RouteTable.latestVersion,
    routes: [
      // No `requires: .privateAPI`: this is the call that TELLS a client whether the
      // Private API is usable for FindMy, so failing it when the helper is absent would
      // withhold exactly the answer being asked for.
      .init(.get, "status", .findmyStatus),
      .init(.post, "friend/refresh", .findmyRefreshFriend, requires: .privateAPI),
      .init(
        .post, "friend/request", .findmyRequestShare,
        scope: .messagesWrite, requires: .privateAPI),
    ])

  /// Sharing this Mac's location out. Gated on `Features.findMyLocationSharing` as
  /// well as `Features.findMy`, and both are off by default.
  ///
  /// A separate group rather than two more routes in `findMy` because the second flag has
  /// to be able to withhold exactly these. What they share is not a capability but a
  /// prefix — everything above reads, everything here transmits the Mac's position to
  /// another person.
  public static let findMySharing = RouteGroup(
    "Find My Sharing", prefix: "icloud/findmy", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(
        .post, "sharing/start", .findmyStartSharing,
        scope: .messagesWrite, requires: .privateAPI),
      .init(
        .post, "sharing/stop", .findmyStopSharing,
        scope: .messagesWrite, requires: .privateAPI),
    ]
  )

  /// Enhanced FaceTime. Additive routes under the same `facetime` prefix as the three
  /// inherited ones (`session`/`answer`/`leave`, which stay in the default table). Gated on
  /// `Features.faceTime`.
  ///
  /// `link` mints a fresh link (Flow A); `call` places a call and hands back a link (Flow B,
  /// always dials); `admit` lets a client
  /// approve a knocker; `members` reads who is in a conversation.
  public static let faceTime = RouteGroup(
    "FaceTime Enhanced", prefix: "facetime", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.post, "link", .facetimeGenerateLink, scope: .chatsWrite, requires: .privateAPI),
      // Invalidate active links. No body → all created links; `{ "urls": [...] }` → those.
      .init(.delete, "link", .facetimeInvalidateLinks, scope: .chatsWrite, requires: .privateAPI),
      // An explicit escape hatch: end the Mac's participation in a call by UUID. The
      // inherited `leave/:call_uuid` exists too; this one takes the UUID in the body so a
      // client that has a call object can hang up without URL-encoding.
      .init(.post, "leave", .facetimeLeaveCall, scope: .chatsWrite, requires: .privateAPI),
      .init(.post, "call", .facetimeCall, scope: .chatsWrite, requires: .privateAPI),
      .init(
        .post, ":group_uuid/admit", .facetimeAdmit,
        scope: .chatsWrite, requires: .privateAPI),
      .init(.get, ":group_uuid/members", .facetimeMembers, requires: .privateAPI),
      // Deliberately NOT `requires: .privateAPI`: the call log is a database read, so
      // recents work with no helper injected. See CallHistoryRepository.
      .init(.get, "recents", .facetimeRecents),
      // Clear stray links and stuck calls. Admin-scoped: it deletes things.
      .init(.post, "cleanup", .facetimeCleanup, scope: .serverAdmin, requires: .privateAPI),
      // FaceTime's counterpart to the inherited `mac/imessage/restart`. It lives HERE, not
      // beside that route, because the default table must match the Node server's exactly —
      // a parity test enforces that, and Node has no FaceTime restart. Restarts FaceTime.app
      // with its Private API helper re-injected.
      .init(.post, "restart", .facetimeRestart, scope: .serverAdmin),
    ] + debugDiagnostics)

  // DEBUG-ONLY DIAGNOSTICS, and compiled out of a release build entirely.
  //
  // `#if DEBUG` rather than a setting or an environment variable on purpose: those are
  // runtime switches, and a runtime switch can be flipped on a production server —
  // including by whoever holds an admin token. These routes hand out raw
  // `TUConversation` internals (`debug`), report another app's UI state (`windows`) and
  // drive that app's UI (`dismiss-alert`). None of it belongs on a shipped API, so the
  // guarantee should be "not in the binary", not "off by default".
  //
  // Alert dismissal still happens in production — automatically, inside
  // `FaceTimeCleanup`, where it is recovery rather than something a client can trigger.

  /// Reachable only in a development build. See the comment above.
  static var debugDiagnostics: [RouteDefinition] {
    #if DEBUG
      return [
        .init(.get, ":group_uuid/debug", .facetimeDebug, requires: .privateAPI),
        .init(.get, "windows", .facetimeWindows, requires: .privateAPI),
        .init(
          .post, "dismiss-alert", .facetimeDismissAlert,
          scope: .chatsWrite, requires: .privateAPI),
      ]
    #else
      return []
    #endif
  }

  /// Incoming-call hand-off (Flow C). Separate group, gated on `Features.faceTimeIncoming`
  /// AND `Features.faceTime`. `handoff` answers a ringing call on behalf of a client and
  /// returns a link to join by.
  public static let faceTimeIncoming = RouteGroup(
    "FaceTime Incoming", prefix: "facetime", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(
        .post, "handoff/:call_uuid", .facetimeHandoff,
        scope: .chatsWrite, requires: .privateAPI)
    ]
  )

  /// Token auth (`docs/AUTH.md` § "Tokens"). NOT registered under `auth_mode = password`,
  /// which is the default — these paths must 404, not 401, so the route table matches the
  /// reference table exactly.
  /// The distinction is asserted in the default-off tests.
  public static let auth = RouteGroup(
    "Auth", prefix: "auth", apiVersion: RouteTable.latestVersion,
    routes: [
      .init(.post, "register", .authRegister, requires: .optionalAuthentication),
      .init(.post, "token", .authToken, requires: .unauthenticated),
      .init(.post, "rotate", .authRotate),
      .init(.post, "revoke", .authRevoke, scope: .serverAdmin),
    ])
}
