//  BBPrivateAPIContract — FindMy
//  The typed FindMy surface, shared by the server and the injected helper.
//
//  These types are a DELIBERATE NARROWING of what IMCore hands out, and the narrowing is the
//  point. `FMLLocation` carries a placemark, a reverse-geocoded address broken into seven
//  fields, floor level, vertical accuracy, speed, an activity state, cached annotation icons
//  and a tint colour. `FMFHandle` carries a DSID, a hashed DSID, alias server ids and an
//  invitation list. None of that is anybody's business over an HTTP API, and several of those
//  fields identify an Apple account rather than a person's position.
//
//  So the rule here is: a field exists because a client has a use for it, not because IMCore
//  exposes it. Anything an integration cannot act on stays inside Messages.app's address
//  space. Where a field maps one-to-one and is already innocuous — latitude, an address
//  string — it passes through unchanged rather than being renamed for the sake of it.
//
//  Header dumps for everything referenced here are in docs/headers/, read from the runtime
//  rather than from an SDK. See docs/headers/README.md.

import Foundation

// MARK: - Locations

/// How fresh a position is, in FindMy's own terms.
///
/// IMCore's `FMLLocation.locationTypeDescription` answers `legacy`, `live` or
/// `proactiveOrShallow`; the shipping server's wire format calls the third one `shallow` and
/// clients switch on that spelling, so it is preserved rather than corrected.
public enum FindMyLocationStatus: String, Codable, Sendable, CaseIterable {
  /// A position pushed by the old FindMyFriends mechanism. Coarse and possibly stale.
  case legacy
  /// A live fix, refreshed on demand.
  case live
  /// Opportunistic — reported by the device passing through, not requested.
  case shallow
  /// The type is present but is not one of the three above. Reported rather than guessed at.
  case unknown

  /// Maps `FMLLocation.locationTypeDescription`, whose vocabulary is not ours.
  public init(locationTypeDescription: String?) {
    switch locationTypeDescription?.lowercased() {
    case "legacy": self = .legacy
    case "live": self = .live
    case "proactiveorshallow", "shallow", "proactive": self = .shallow
    default: self = .unknown
    }
  }

  /// Maps the numeric `locationType` used by the legacy `FMFLocation` path.
  ///
  /// The mapping is the shipping Objective-C helper's, verbatim
  /// (BlueBubblesHelper.m:1413): 0 is legacy, 2 is live, anything else is shallow.
  public init(legacyLocationType: Int) {
    switch legacyLocationType {
    case 0: self = .legacy
    case 2: self = .live
    default: self = .shallow
    }
  }
}

/// Where someone is, as much of it as a client can act on.
///
/// Every positional field is optional because "sharing with me but not currently locatable"
/// is an ordinary state, not an error — the friend exists, the coordinates do not yet. A
/// client that renders a pin needs to tell that apart from a friend it has never heard of,
/// and collapsing both to an absent entry would make that impossible.
public struct FindMyLocation: Codable, Sendable, Equatable {
  public let latitude: Double?
  public let longitude: Double?
  /// Metres. FindMy's own accuracy circle radius.
  public let horizontalAccuracy: Double?
  /// Metres above sea level, when the device reported one.
  public let altitude: Double?
  /// Reverse-geocoded, and only present when the refresh asked for geocoding.
  public let shortAddress: String?
  public let longAddress: String?
  /// FindMy's own one-line label for the place — "Home", "Apple Park".
  public let label: String?
  public let lastUpdated: Date?
  /// A fix is in flight. A client should show a spinner rather than treating the position
  /// below as final.
  public let isLocatingInProgress: Bool
  public let status: FindMyLocationStatus

  public init(
    latitude: Double? = nil,
    longitude: Double? = nil,
    horizontalAccuracy: Double? = nil,
    altitude: Double? = nil,
    shortAddress: String? = nil,
    longAddress: String? = nil,
    label: String? = nil,
    lastUpdated: Date? = nil,
    isLocatingInProgress: Bool = false,
    status: FindMyLocationStatus = .unknown
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracy = horizontalAccuracy
    self.altitude = altitude
    self.shortAddress = shortAddress
    self.longAddress = longAddress
    self.label = label
    self.lastUpdated = lastUpdated
    self.isLocatingInProgress = isLocatingInProgress
    self.status = status
  }

  /// Whether there is a position at all.
  ///
  /// `(0, 0)` is treated as absent on purpose: IMCore reports a friend with no fix as the
  /// origin rather than as nil, and an integration that trusts it drops a pin in the Gulf
  /// of Guinea. The shipping server's friends cache makes the same exclusion.
  public var hasCoordinates: Bool {
    guard let latitude, let longitude else { return false }
    return !(latitude == 0 && longitude == 0)
  }
}

// MARK: - Friends

/// One person in the FindMy relationship graph, with their position if we have one.
///
/// The two booleans are separate because the relationship is not symmetric and clients need
/// both halves: someone can share with me while I do not share with them, and a UI that
/// offers "stop sharing" against a one-way follower is offering something that does nothing.
public struct FindMyFriend: Codable, Sendable, Equatable {
  /// The address FindMy knows them by — a phone number or an email. This is the join key
  /// against a handle in chat.db, and the only identifier exposed: `FMFHandle` also carries
  /// a DSID and a hashed DSID, which identify the Apple account itself and are withheld.
  public let handle: String
  public let isSharingWithMe: Bool
  public let isFollowingMyLocation: Bool
  public let location: FindMyLocation?

  public init(
    handle: String,
    isSharingWithMe: Bool,
    isFollowingMyLocation: Bool,
    location: FindMyLocation? = nil
  ) {
    self.handle = handle
    self.isSharingWithMe = isSharingWithMe
    self.isFollowingMyLocation = isFollowingMyLocation
    self.location = location
  }
}

// MARK: - Status

/// Which IMCore path is answering.
///
/// Worth reporting because the two are not equivalent — the legacy path has no per-handle
/// refresh and no reverse geocoding — and because a support conversation that starts with
/// "which backend" is much shorter than one that starts with "it doesn't work".
public enum FindMyBackend: String, Codable, Sendable {
  /// `FindMyLocateSession`, via `IMFMFSession.fmlSession`. The modern path.
  case findMyLocate = "findmy-locate"
  /// The legacy `FMFSession`, via `IMFMFSession.session`.
  case legacyFindMyFriends = "legacy-fmf"
  /// `IMFMFSession` exists but has no session — FindMy is not set up on this Mac.
  case none
}

/// The Mac this server runs on, as FindMy sees it.
///
/// Only the two facts a client can act on. `FMLDevice` also carries an IDS device id and an
/// internal identifier, which are stable per-device identifiers for the user's hardware and
/// are not exposed.
public struct FindMyDeviceSummary: Codable, Sendable, Equatable {
  public let name: String?
  /// Whether the *active location sharing device* is this Mac. When it is not, the position
  /// this account shares comes from the user's phone, and location sharing initiated here
  /// still reports the phone's position.
  public let isThisDevice: Bool

  public init(name: String?, isThisDevice: Bool) {
    self.name = name
    self.isThisDevice = isThisDevice
  }
}

/// Whether FindMy is usable at all, and why not when it is not.
///
/// This is the call a client should make BEFORE showing any FindMy UI. On a Mac where the
/// user never signed into iCloud, or where location sharing is restricted by a profile, every
/// other call here fails in a way that reads as a bug; asking this first turns that into a
/// hidden tab.
public struct FindMyStatus: Codable, Sendable, Equatable {
  /// A session exists and calls will be attempted. False means every other FindMy call
  /// will fail, and a client should not offer the feature.
  public let isAvailable: Bool
  /// The account is provisioned for location sharing with iCloud.
  public let isProvisioned: Bool
  /// Restricted by policy — Screen Time, or a configuration profile. Not something the
  /// server or the user can change from here.
  public let isRestricted: Bool
  /// Sharing is switched off for this account. Distinct from `isRestricted`: this one the
  /// user can undo in System Settings.
  public let isSharingDisabled: Bool
  public let backend: FindMyBackend
  public let activeDevice: FindMyDeviceSummary?

  public init(
    isAvailable: Bool,
    isProvisioned: Bool,
    isRestricted: Bool,
    isSharingDisabled: Bool,
    backend: FindMyBackend,
    activeDevice: FindMyDeviceSummary? = nil
  ) {
    self.isAvailable = isAvailable
    self.isProvisioned = isProvisioned
    self.isRestricted = isRestricted
    self.isSharingDisabled = isSharingDisabled
    self.backend = backend
    self.activeDevice = activeDevice
  }

  /// Nothing is set up. The shape returned when `IMFMFSession` itself is missing.
  public static let unavailable = FindMyStatus(
    isAvailable: false, isProvisioned: false, isRestricted: false,
    isSharingDisabled: true, backend: .none
  )
}

// MARK: - Sharing

/// How long to share for.
///
/// Exactly the three IMCore accepts, and no more. `-[IMFMFSession _dateFromShareDuration:]`
/// reads its argument as: 0 is one hour, 1 is the end of the current day, and **anything
/// else** produces a nil expiry, which means indefinitely. Read from the disassembly on macOS
/// 26.5.2 — see docs/headers/README.md.
///
/// Modelled as an enum rather than passing the integer through so that a client cannot send
/// `7` and get an indefinite share it did not ask for, which is what the raw call does.
public enum FindMyShareDuration: String, Codable, Sendable, CaseIterable {
  case oneHour = "one-hour"
  case untilEndOfDay = "until-end-of-day"
  case indefinitely

  /// The value `startSharingWith…:withDuration:` expects.
  public var imCoreValue: Int {
    switch self {
    case .oneHour: 0
    case .untilEndOfDay: 1
    // 2 is not a documented value; it is simply not 0 or 1, which is what produces the
    // nil expiry. Named rather than left as a magic number.
    case .indefinitely: 2
    }
  }
}

/// Who to share with.
///
/// A chat is always required, even when an address is given, and that is IMCore's shape
/// rather than a simplification of ours: `startSharingWithHandle:inChat:withDuration:` uses
/// the chat to pick the caller ID the offer is sent from. There is no chat-less form, and
/// passing nil would send the offer from whichever alias IMCore happened to pick.
public struct FindMyShareRequest: Codable, Sendable {
  public let chat: ChatGUID
  /// One participant, or nil for every participant in the chat.
  public let address: String?
  public let duration: FindMyShareDuration

  public init(chat: ChatGUID, address: String? = nil, duration: FindMyShareDuration) {
    self.chat = chat
    self.address = address
    self.duration = duration
  }
}
