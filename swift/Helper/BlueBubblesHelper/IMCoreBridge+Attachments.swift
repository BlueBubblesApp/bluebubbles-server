//  IMCoreBridge+Attachments
//  Fetching an attachment Messages purged to iCloud, and the FindMy surface.
//  `AttachmentAccess` and `FindMyAccess`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. ObjC: `download-purged-attachment` (BlueBubblesHelper.m:663).
  ///
  /// Register the transfer with the daemon, then ACCEPT it; that pair is what starts the
  /// fetch. An earlier pass called `_initiateLocalFileURLRetrievalInDaemonForGUID:options:`,
  /// which is a different mechanism and does not un-purge.
  ///
  /// Returns as soon as the daemon accepts. The transfer itself is asynchronous and of
  /// unknown size; the file appears in chat.db when it completes.
  public func downloadPurgedAttachment(guid: String) async throws -> String {
    try translating {
      let center = try IMFileTransfers.center()
      guard let transfer = try IMCoreRuntime.send(center, "transferForGUID:", guid) else {
        throw PrivateAPIErrorShim.rejected("Messages has no transfer with GUID \(guid)")
      }

      // Already here, or outgoing; either way there is nothing to un-purge. The
      // reference reports this rather than starting a pointless fetch.
      let state = (try? IMCoreRuntime.integer(transfer, "transferState")) ?? 0
      let incoming = (try? IMCoreRuntime.bool(transfer, "isIncoming")) ?? false
      if state != 0 || !incoming {
        if let path = ((try? IMCoreRuntime.string(transfer, "localPath")) ?? nil),
          !path.isEmpty
        {
          return path
        }
        throw PrivateAPIErrorShim.rejected(
          "transfer \(guid) does not need un-purging"
        )
      }

      try IMCoreRuntime.invoke(center, "registerTransferWithDaemon:", [guid])
      try IMCoreRuntime.invoke(center, "acceptTransfer:", [guid])

      return ((try? IMCoreRuntime.string(transfer, "localPath")) ?? nil) ?? ""
    }
  }

  //
  // PORTED.
  //
  // Messages does not load FindMy's frameworks, which makes these look unreachable. They are
  // not: `IMFMFSession` is an IMCore class and is in the address space from launch, and what
  // is genuinely absent on macOS 26 is the LEGACY family. The runtime evidence is at the top
  // of FindMyBridge.swift.
  //
  // Everything here delegates there. Keeping the IMCore calls in their own file rather than
  // inline is what makes the FindMy surface reviewable as one thing; it is the largest
  // block of private-framework work in the helper, and it is the one most likely to need
  // re-verifying against a new macOS.
  public func findMyStatus() async throws -> FindMyStatus {
    // Deliberately not wrapped in `translating`: this call answers rather than fails.
    // A Mac with no FindMy at all is a supported configuration, and reporting it as an
    // error would be indistinguishable from the helper being broken.
    FindMyBridge.status()
  }

  public func findMyFriends() async throws -> [FindMyFriend] {
    try translating { try FindMyBridge.friends() }
  }

  public func refreshFindMyFriends() async throws -> [FindMyFriend] {
    try await FindMyBridge.refreshAll()
  }

  public func refreshFindMyLocation(handle: String) async throws -> FindMyFriend {
    try await FindMyBridge.refresh(handle: handle)
  }

  public func requestFindMyLocationShare(handle: String) async throws {
    try await FindMyBridge.requestLocationShare(handle: handle)
  }

  public func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws {
    try translating { try FindMyBridge.startSharing(request) }
  }

  public func stopSharingFindMyLocation(chat: ChatIdentifier, address: String?) async throws {
    try translating { try FindMyBridge.stopSharing(chat: chat, address: address) }
  }
}
