//  WireCodecs
//  The helper-wire encoding of each contract type a reply or an event carries.
//
//  Each conformance is the whole format for its type: what the helper writes and what the
//  server reads, side by side, so a change to one is a change to both. The rule for an
//  absent field is `WireCodec.swift`'s: required unless the comment on the field says what
//  its absence means.

import Foundation

// MARK: - Mute

extension ChatMuteState: WireCodable {
  public var wire: WireObject {
    [
      .isMuted: isMuted,
      .isIndefinite: isIndefinite,
      // OMITTED for an indefinite mute rather than sent as the year 4001, which a client
      // showing "muted until <date>" would render as a date.
      .mutedUntil: mutedUntil?.wireMilliseconds,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      isMuted: try wire.bool(.isMuted),
      // Absent means no end date: indefinite, or not muted.
      mutedUntil: try wire.optionalDate(.mutedUntil),
      isIndefinite: try wire.bool(.isIndefinite)
    )
  }
}

// MARK: - Filtering and spam

extension ChatFilterState: WireCodable {
  public var wire: WireObject {
    [
      .isFiltered: isFiltered,
      .filterCategory: filterCategory,
      .isKnownSender: isKnownSender,
      .isInUnknownSendersFilter: isInUnknownSendersFilter,
      .wasDetectedAsSMSSpam: wasDetectedAsSMSSpam,
      .canReportJunk: canReportJunk,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      isFiltered: try wire.int(.isFiltered),
      // Absent means this release cannot say: macOS 27 has no getter, and 0 would claim
      // the inbox.
      filterCategory: try wire.optionalInt(.filterCategory),
      isKnownSender: try wire.bool(.isKnownSender),
      isInUnknownSendersFilter: try wire.bool(.isInUnknownSendersFilter),
      wasDetectedAsSMSSpam: try wire.bool(.wasDetectedAsSMSSpam),
      canReportJunk: try wire.bool(.canReportJunk)
    )
  }
}

/// Only the keys this release could answer.
///
/// Every field's absence means "this release cannot say", and a `false` would be "no".
/// Conflating them is the `canReportJunk` defect, where a missing selector was reported as a
/// working feature being unavailable.
extension ChatPresentationState: WireCodable {
  public var wire: WireObject {
    [
      .shouldPresentSpamReasonPicker: shouldPresentSpamReasonPicker,
      .isReportedAsSpam: isReportedAsSpam,
      .wasDetectedAsSMSSpam: wasDetectedAsSMSSpam,
      .wasDetectedAsSpam: wasDetectedAsSpam,
      .isKnownChat: isKnownChat,
      .completedInitialChatMessagesLoad: completedInitialChatMessagesLoad,
      .isSMSSpamFilteringEnabled: isSMSSpamFilteringEnabled,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      shouldPresentSpamReasonPicker: try wire.optionalBool(.shouldPresentSpamReasonPicker),
      isReportedAsSpam: try wire.optionalBool(.isReportedAsSpam),
      wasDetectedAsSMSSpam: try wire.optionalBool(.wasDetectedAsSMSSpam),
      wasDetectedAsSpam: try wire.optionalBool(.wasDetectedAsSpam),
      isKnownChat: try wire.optionalBool(.isKnownChat),
      completedInitialChatMessagesLoad: try wire.optionalBool(.completedInitialChatMessagesLoad),
      isSMSSpamFilteringEnabled: try wire.optionalBool(.isSMSSpamFilteringEnabled)
    )
  }
}

extension ChatSpamResult: WireCodable {
  public var wire: WireObject {
    [
      .messageCount: messageCount,
      .reportedToCarrier: reportedToCarrier,
      .dryRun: wasDryRun,
      .filter: filter.wire,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      messageCount: try wire.int(.messageCount),
      reportedToCarrier: try wire.bool(.reportedToCarrier),
      wasDryRun: try wire.bool(.dryRun),
      filter: try wire.decode(.filter)
    )
  }
}

// MARK: - FindMy

extension FindMyDeviceSummary: WireCodable {
  public var wire: WireObject {
    [.name: name, .isThisDevice: isThisDevice]
  }

  public init(wire: WireReader) throws {
    self.init(
      // Absent when FindMy has no name for the device.
      name: try wire.optionalString(.name),
      isThisDevice: try wire.bool(.isThisDevice)
    )
  }
}

extension FindMyStatus: WireCodable {
  public var wire: WireObject {
    [
      .available: isAvailable,
      .provisioned: isProvisioned,
      .restricted: isRestricted,
      .sharingDisabled: isSharingDisabled,
      .backend: backend.rawValue,
      .activeDevice: activeDevice?.wire,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      isAvailable: try wire.bool(.available),
      isProvisioned: try wire.bool(.provisioned),
      isRestricted: try wire.bool(.restricted),
      isSharingDisabled: try wire.bool(.sharingDisabled),
      backend: try wire.value(.backend, as: FindMyBackend.self),
      // Absent when FindMy reports no active location-sharing device.
      activeDevice: try wire.optionalDecode(.activeDevice)
    )
  }
}

extension FindMyLocation: WireCodable {
  public var wire: WireObject {
    // The coordinates go out only as a pair, and only when there IS a fix. IMCore reports
    // an unlocated friend at the origin rather than as nil, and a client that trusts that
    // drops a pin in the Gulf of Guinea, so the check is here, once, rather than in every
    // client. A non-finite reading is dropped the same way: JSON has no form for it.
    let fix = hasCoordinates && latitude?.wireFinite != nil && longitude?.wireFinite != nil
    return [
      .latitude: fix ? latitude : nil,
      .longitude: fix ? longitude : nil,
      .horizontalAccuracy: horizontalAccuracy?.wireFinite,
      .altitude: altitude?.wireFinite,
      .shortAddress: shortAddress,
      .longAddress: longAddress,
      .label: label,
      .lastUpdated: lastUpdated?.wireMilliseconds,
      .isLocatingInProgress: isLocatingInProgress,
      .status: status.rawValue,
    ]
  }

  /// Every positional field's absence means "not located" or "not reported", which is an
  /// ordinary state for someone who shares with us; see the type.
  public init(wire: WireReader) throws {
    self.init(
      latitude: try wire.optionalDouble(.latitude),
      longitude: try wire.optionalDouble(.longitude),
      horizontalAccuracy: try wire.optionalDouble(.horizontalAccuracy),
      altitude: try wire.optionalDouble(.altitude),
      shortAddress: try wire.optionalString(.shortAddress),
      longAddress: try wire.optionalString(.longAddress),
      label: try wire.optionalString(.label),
      lastUpdated: try wire.optionalDate(.lastUpdated),
      isLocatingInProgress: try wire.bool(.isLocatingInProgress),
      status: try wire.value(.status, as: FindMyLocationStatus.self)
    )
  }
}

extension FindMyFriend: WireCodable {
  public var wire: WireObject {
    [
      .handle: handle,
      .isSharingWithMe: isSharingWithMe,
      .isFollowingMyLocation: isFollowingMyLocation,
      .location: location?.wire,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      handle: try wire.string(.handle),
      isSharingWithMe: try wire.bool(.isSharingWithMe),
      isFollowingMyLocation: try wire.bool(.isFollowingMyLocation),
      // Absent for a friend FindMy has no location object for at all.
      location: try wire.optionalDecode(.location)
    )
  }
}

// MARK: - FaceTime

extension FaceTimeLink: WireCodable {
  public var wire: WireObject {
    [
      .url: url,
      .groupUUID: groupUUID,
      .name: name,
      .expiresAt: expiresAt?.wireMilliseconds,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      url: try wire.string(.url),
      // Each absent when TelephonyUtilities did not supply it; all three are optional on
      // `TUConversationLink`.
      groupUUID: try wire.optionalString(.groupUUID),
      name: try wire.optionalString(.name),
      expiresAt: try wire.optionalDate(.expiresAt)
    )
  }
}

/// The handle is flattened into the call: `handle` and `displayName` at the top level, both
/// absent on a group call with no single peer.
extension FaceTimeCall: WireCodable {
  public var wire: WireObject {
    [
      .callUUID: callUUID,
      .callStatus: status.rawValue,
      // The name beside the number, for a human reading a frame; the decoder reads the
      // number, which is the authority.
      .status: status.name,
      .handle: handle?.value,
      .displayName: handle?.displayName,
      .groupUUID: groupUUID,
      .isVideo: isVideo,
      .callerIDBlocked: callerIDBlocked,
    ]
  }

  public init(wire: WireReader) throws {
    let handle = try wire.optionalString(.handle)
    let displayName = try wire.optionalString(.displayName)
    self.init(
      callUUID: try wire.string(.callUUID),
      status: FaceTimeCallStatus(raw: try wire.int(.callStatus)),
      handle: handle.map { FaceTimeHandle(value: $0, displayName: displayName) },
      // Absent until the call belongs to a conversation.
      groupUUID: try wire.optionalString(.groupUUID),
      isVideo: try wire.bool(.isVideo),
      callerIDBlocked: try wire.bool(.callerIDBlocked)
    )
  }
}

/// The handle is flattened into the member: `handle` and `displayName` at the top level.
extension FaceTimeMember: WireCodable {
  public var wire: WireObject {
    [
      .handle: handle.value,
      .displayName: handle.displayName,
      .nickname: nickname,
      .isActive: isActive,
      .isLightweight: isLightweight,
      .isPending: isPending,
      .isWaitingToBeLetIn: isWaitingToBeLetIn,
      .joinedFromLetMeIn: joinedFromLetMeIn,
    ]
  }

  public init(wire: WireReader) throws {
    self.init(
      handle: FaceTimeHandle(
        value: try wire.string(.handle),
        // Absent when FaceTime resolved no name for the address.
        displayName: try wire.optionalString(.displayName)
      ),
      // Absent for anyone who did not type one, which is everyone but a link guest.
      nickname: try wire.optionalString(.nickname),
      isPending: try wire.bool(.isPending),
      isWaitingToBeLetIn: try wire.bool(.isWaitingToBeLetIn),
      joinedFromLetMeIn: try wire.bool(.joinedFromLetMeIn),
      // Required, never inferred from `isPending`: presence is what the hand-off counts
      // on, and a guess at it is how the Mac left calls nobody had joined.
      isActive: try wire.bool(.isActive),
      isLightweight: try wire.bool(.isLightweight)
    )
  }
}
