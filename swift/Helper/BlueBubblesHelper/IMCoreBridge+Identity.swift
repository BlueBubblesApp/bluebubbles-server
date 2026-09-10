//  IMCoreBridge+Identity
//  Who this Mac is and who it can reach: availability checks, the account, aliases
//  and nicknames. `HandleAvailability` and `AccountAccess`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. ObjC: `check-imessage-availability` (BlueBubblesHelper.m:637).
  ///
  /// Forces an IDS refresh rather than reading `IMHandle.IDStatus`. That cached value is 0
  /// (UNKNOWN) until something asks IDS, and an earlier pass of this port read it directly,
  /// so a real iMessage address came back unavailable and a client would send it as SMS.
  /// Verified live: the cached read returned false for an address that is on iMessage.
  public func checkIMessageAvailability(address: String) async throws -> Bool {
    try await IMCoreQueries.idsStatus(address: address, service: "com.apple.madrid")
  }

  /// PORTED. ObjC: `check-facetime-availability` (BlueBubblesHelper.m:637).
  ///
  /// A DIFFERENT IDS service from iMessage, and that is the whole content of this method.
  /// An earlier pass delegated to `checkIMessageAvailability`, which answers a different
  /// question: an address can be on one service and not the other.
  public func checkFaceTimeAvailability(address: String) async throws -> Bool {
    try await IMCoreQueries.idsStatus(
      address: address, service: "com.apple.private.alloy.facetime.multi")
  }

  /// PORTED. ObjC: `check-focus-status` (BlueBubblesHelper.m:590). Monterey and later.
  ///
  /// `IMHandleAvailabilityManager`, refreshed then read, not a `focusStatus` property on
  /// the handle, which an earlier pass invented and which does not exist. Status 2 means
  /// the recipient has notifications silenced.
  public func checkFocusStatus(address: String) async throws -> String {
    guard let handle = try IMAccountController.handle(for: address) else {
      throw PrivateAPIError.rejectedByMessages(reason: "no handle for \(address)")
    }
    let status = try await IMCoreQueries.focusStatus(handle: handle.object)
    // 2 is silenced. Everything else is "not known to be silenced", which is the common
    // case (most people have not shared a Focus status) and renders as nothing.
    return status == 2 ? "silenced" : "available"
  }

  /// PORTED. ObjC: `get-account-info`: the active iMessage account.
  ///
  /// The first ACTIVE account, not the first account: a Mac signed out of iMessage still
  /// has an account object, and reporting its login as the user's identity is how a client
  /// ends up showing an address that cannot send anything.
  public func accountInfo() async throws -> AccountInfo {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
      let active = (try? IMCoreRuntime.objects(controller, "activeAccounts")) ?? []
      guard let account = active.first else {
        throw PrivateAPIErrorShim.rejected(
          "no active iMessage account: this Mac is signed out of Messages"
        )
      }

      let strings: (String) -> [String] = { selector in
        ((try? IMCoreRuntime.objects(account, selector)) ?? [])
          .compactMap { $0 as? String }
      }
      let aliases = strings("aliases")
      return AccountInfo(
        // `strippedLogin` drops the `E:` / `P:` service prefix IMCore carries
        // internally; `login` keeps it, and a client displaying `E:me@example.com`
        // looks broken.
        appleId: ((try? IMCoreRuntime.string(account, "strippedLogin")) ?? nil)
          ?? ((try? IMCoreRuntime.string(account, "login")) ?? nil),
        activeAlias: ((try? IMCoreRuntime.string(account, "displayName")) ?? nil)
          ?? aliases.first,
        aliases: aliases,
        vettedAliases: strings("vettedAliases")
      )
    }
  }

  /// PORTED. ObjC: `get-nickname-info`: IMNicknameController.
  ///
  /// A nickname is the name and photo someone chose to share, which is distinct from
  /// anything in Contacts. Not having one is the common case, so an absent nickname is an
  /// empty result rather than an error.
  ///
  /// **Two selectors, chosen by whether an address was given.** A nil address means the
  /// LOCAL user's own card (the shape `icloud.contactCard` returns by default, and the one
  /// the reference server's fixture records) and the controller exposes that as
  /// `personalNickname` rather than as a lookup of one's own handle.
  ///
  /// Both return an **`IMNickname` object, not a dictionary.** Subscripting the result of
  /// `currentNicknameForHandleIDs:` as `[String: Any]` and reading `entry["name"]` cannot
  /// work: the values are objects, so every lookup returns nil and the method reports "no
  /// shared nickname" for everyone. The properties are read through `IMCoreRuntime` here,
  /// verified against the live class:
  ///
  ///     IMNickname       displayName, firstName, lastName, handle, avatar
  ///     IMNicknameAvatarImage   imageFilePath, imageExists, hasImage
  ///
  /// See `docs/headers/macos-26.5.2/IMNickname.h`.
  public func nicknameInfo(for address: String?) async throws -> NicknameInfo {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMNicknameController")

      // `nicknameForHandleIDs:` takes an ARRAY OF STRINGS. Its sibling
      // `nicknameForHandle:` takes an `IMHandle` OBJECT, and handing it a string raises
      // `-[Swift.__StringStorage ID]: unrecognized selector`; measured, and contained by
      // `IMCoreRuntime` rather than terminating Messages, which is what that layer is for.
      var nickname: AnyObject?
      if let address {
        let found = try IMCoreRuntime.invoke(
          controller, "nicknameForHandleIDs:", [[address]]
        )
        // Keyed by handle when several are requested, and a bare nickname when one is;
        // both spellings are accepted rather than assuming which.
        if let byHandle = found as? [String: AnyObject] {
          nickname = byHandle[address] ?? byHandle.values.first
        } else {
          nickname = found as AnyObject?
        }
      } else {
        nickname = try IMCoreRuntime.invoke(controller, "personalNickname", []) as AnyObject?
      }
      guard let nickname else {
        return NicknameInfo(handle: address, name: nil, hasSharedNickname: false)
      }

      // `displayName` is what Messages shows. Falling back to the name components rather
      // than to nil: a card can carry a first and last name with no composed display name,
      // and reporting "no nickname" for one would be wrong.
      let display = (try? IMCoreRuntime.string(nickname, "displayName")) ?? nil
      let first = (try? IMCoreRuntime.string(nickname, "firstName")) ?? nil
      let last = (try? IMCoreRuntime.string(nickname, "lastName")) ?? nil
      let composed = [first, last].compactMap { $0 }.joined(separator: " ")
      let name = display ?? (composed.isEmpty ? nil : composed)

      // The avatar is a separate object, and it may exist while its file does not: the
      // photo is fetched lazily, so a card can name a path nothing has downloaded yet.
      // `imageExists` is checked so the server is not handed a path it cannot read.
      var avatarPath: String?
      if let avatar = (try? IMCoreRuntime.invoke(nickname, "avatar", [])) as AnyObject?,
        (try? IMCoreRuntime.bool(avatar, "imageExists")) ?? false
      {
        avatarPath = (try? IMCoreRuntime.string(avatar, "imageFilePath")) ?? nil
      }

      return NicknameInfo(
        handle: address ?? ((try? IMCoreRuntime.string(nickname, "handle")) ?? nil),
        name: name,
        hasSharedNickname: name != nil || avatarPath != nil,
        avatarPath: avatarPath
      )
    }
  }

  /// PORTED. ObjC: `shouldOfferNicknameSharingForChat:` (BlueBubblesHelper.m:680).
  ///
  /// On the CONTROLLER, taking the chat, not a property of the chat. Asking the chat
  /// reports it as unavailable on this macOS when it is not.
  public func shouldOfferNicknameSharing(chat: ChatIdentifier) async throws -> Bool {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMNicknameController")
      let result = try IMCoreRuntime.invoke(
        controller, "shouldOfferNicknameSharingForChat:", [conversation.object]
      )
      return (result as? NSNumber)?.boolValue ?? false
    }
  }

  /// PORTED. ObjC: `whitelistHandlesForNicknameSharing:forChat:` (BlueBubblesHelper.m:689).
  ///
  /// FOUR selector generations, newest first, because Apple has changed the ARITY rather
  /// than the name. The two the reference knows about (`whitelistHandlesForNicknameSharing:`
  /// and the two-argument `allowHandlesForNicknameSharing:forChat:`) are **both absent on
  /// macOS 26.5.2**, so this method reported `unavailableOnThisOS` on the very OS the port
  /// is developed against, and had presumably never worked. See
  /// `docs/SEQUOIA_COMPATIBILITY.md` §5.1.
  ///
  ///   macOS 26   …ForNicknameSharing:forChat:fromHandle:forceSend:
  ///   macOS 26   …ForNicknameSharing:fromHandle:forceSend:      (no chat scope)
  ///   older      …ForNicknameSharing:forChat:
  ///   oldest     whitelistHandlesForNicknameSharing:forChat:
  ///
  /// `fromHandle:` is **this Mac's own handle**, not a participant's: it is the "from" of
  /// the share. That it is an `IMHandle` and not a handle-ID string was read off the
  /// disassembly rather than guessed: the local method converts every OTHER handle argument
  /// with `_handleIDsForHandle:` before forwarding to
  /// `IMDaemonAnyProtocol.allowHandleIDsForNicknameSharing:onChatGUIDs:fromHandle:forceSend:`,
  /// and the daemon's parameter names record each of those conversions: `allowHandles` →
  /// `allowHandleIDs`, `forChat` → `onChatGUIDs`. `fromHandle:` keeps its name across the
  /// boundary, so it keeps its type.
  ///
  /// `forceSend:` is false. True re-sends a nickname the recipient already has, which is
  /// not what a client asking to share one is asking for.
  public func shareNickname(chat: ChatIdentifier) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let participants =
        (try? IMCoreRuntime.objects(
          conversation.object, "participants"
        )) ?? []
      guard !participants.isEmpty else {
        throw PrivateAPIErrorShim.rejected("that conversation has no participants")
      }

      // NSNull, not a skipped argument: the modern selectors take `fromHandle:`
      // positionally, and IMCore forwards it without messaging it, so an explicit nil
      // is a valid "no local handle" rather than a crash waiting to happen.
      let sender: Any = IMAccountController.loginHandle() ?? NSNull()
      let force = NSNumber(value: false)

      let candidates: [(String, [Any])] = [
        (
          "allowHandlesForNicknameSharing:forChat:fromHandle:forceSend:",
          [participants, conversation.object, sender, force]
        ),
        (
          "allowHandlesForNicknameSharing:fromHandle:forceSend:",
          [participants, sender, force]
        ),
        (
          "allowHandlesForNicknameSharing:forChat:",
          [participants, conversation.object]
        ),
        (
          "whitelistHandlesForNicknameSharing:forChat:",
          [participants, conversation.object]
        ),
      ]

      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMNicknameController")
      for (selector, arguments) in candidates
      where IMCoreRuntime.responds(controller, to: NSSelectorFromString(selector)) {
        try IMCoreRuntime.invoke(controller, selector, arguments)
        return
      }
      throw PrivateAPIError.unavailableOnThisOS(
        method: "shareNickname",
        requires: "an IMNicknameController sharing selector this macOS has"
      )
    }
  }

  /// PORTED. ObjC: `[account setDisplayName:]` (BlueBubblesHelper.m:748).
  ///
  /// `IMAccount` has no `setActiveAlias:`, and looking for one is the wrong search: the
  /// active sending alias IS the account's display name, which the reference sets directly.
  /// A dump of `IMAccount` confirms `setDisplayName:` is present.
  public func modifyActiveAlias(_ alias: String) async throws {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
      guard let account = try IMCoreRuntime.send(controller, "activeIMessageAccount") else {
        throw PrivateAPIErrorShim.rejected(
          "no active iMessage account: this Mac is signed out of Messages"
        )
      }
      // Refused rather than set to something the account does not own: an alias that
      // is not on the account is silently ignored by Messages, so the caller would see
      // success and no change.
      let aliases = ((try? IMCoreRuntime.objects(account, "aliases")) ?? [])
        .compactMap { $0 as? String }
      guard aliases.isEmpty || aliases.contains(alias) else {
        throw PrivateAPIErrorShim.rejected(
          "\(alias) is not one of this account's aliases"
        )
      }
      try IMCoreRuntime.invoke(account, "setDisplayName:", [alias])
    }
  }
}
