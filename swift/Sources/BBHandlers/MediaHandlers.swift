//  MediaHandlers
//  Controllers for attachments beyond the plain download, group icons, and media statistics.

import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

public enum MediaHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    registerAttachments(into: &registry, context: context)
    registerGroupIcons(into: &registry, context: context)
    registerBackgrounds(into: &registry, context: context)
    registerStatistics(into: &registry, context: context)
    registerNicknames(into: &registry, context: context)
    registerFindMyDevices(into: &registry, context: context)
  }

  // MARK: - Attachments

  private static func registerAttachments(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    // Same as `attachment.download`, except it insists on pulling a purged attachment
    // back from iCloud rather than reporting it missing. Separate route because that can
    // take minutes — the table gives it a one-hour timeout for exactly that reason.
    registry.register(.attachmentForceDownload) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let api = try await context.requirePrivateAPI(for: "downloading a purged attachment")
      let path = try await api.downloadPurgedAttachment(guid: guid)
      let metadata = try await interfaces.attachment.find(guid: guid)
      return .file(
        path: path,
        filename: metadata?.transferName,
        contentType: metadata?.mimeType ?? FileTypes.mimeType(for: path)
      )
    }

    /// The video half of a Live Photo.
    ///
    /// Apple stores it beside the still with the same basename and a `.mov` extension.
    /// Derived from the still's path rather than looked up, because chat.db has no row
    /// for it — it is not an attachment, it is a sidecar file.
    registry.register(.attachmentDownloadLive) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let still = try await interfaces.attachment.resolvePath(guid: guid)

      let base = (still as NSString).deletingPathExtension
      let candidates = ["\(base).mov", "\(base).MOV"]
      guard
        let motion = candidates.first(where: {
          FileManager.default.fileExists(atPath: $0)
        })
      else {
        throw NotFound("attachment \(guid) has no Live Photo video alongside it")
      }
      return .file(
        path: motion,
        filename: (motion as NSString).lastPathComponent,
        contentType: "video/quicktime"
      )
    }
  }

  // MARK: - Group icons

  private static func registerGroupIcons(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    /// Reads the group photo off disk — no helper needed, which is why the route table
    /// scopes it to `attachments:read` rather than requiring the Private API.
    registry.register(.chatGroupIcon) { request in
      let guid = try request.requirePathParameter("guid")
      let path = try await context.requireInterfaces().chat.groupIconPath(guid: guid)
      return .file(
        path: path,
        filename: (path as NSString).lastPathComponent,
        contentType: FileTypes.mimeType(for: path)
      )
    }

    registry.register(.chatRemoveGroupIcon) { request in
      let guid = try request.requirePathParameter("guid")
      let api = try await context.requirePrivateAPI(for: "removing a group photo")
      // An empty path is how IMCore is told to clear the photo rather than set one.
      try await api.updateGroupPhoto(chat: ChatGUID(guid), imagePath: "")
      return .data(nil)
    }
  }

  // MARK: - Chat backgrounds
  //
  // The wallpaper a conversation shows. Reading it needs no helper at all — see
  // `TranscriptBackground` for why the `-watchBackground` file is the whole trick — which
  // is why these two land ahead of setting one.

  private static func registerBackgrounds(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    /// The image itself. Same shape as `chat.groupIcon`: bytes, or a 404 that says which
    /// of the two nothing-to-serve cases this is.
    registry.register(.chatBackground) { request in
      let chat = try await Self.chatRow(request, context: context)
      switch TranscriptBackground.asset(for: chat.properties) {
      case .success(let asset):
        return .bytes(asset.imageData, contentType: asset.contentType)
      case .failure(.none):
        throw NotFound("that chat has no background set")
      case .failure(.notDownloaded(let identifier)):
        // NOT the same answer as "no background", and a client syncing wallpapers
        // has to tell them apart: this one is worth retrying, the other is not.
        //
        // So rather than only saying so, ASK for it. The download is a daemon call
        // with no completion, so the request is fired and the file is watched for —
        // and only when the caller asked to wait, since a GET that blocks for five
        // seconds by default is its own kind of bug.
        let requested = await Self.requestBackgroundDownload(
          chatGUID: chat.guid, context: context
        )
        if let asset = await Self.waitForBackground(
          identifier: identifier, seconds: Self.requestedWait(request)
        ) {
          return .bytes(asset.imageData, contentType: asset.contentType)
        }
        throw NotFound(
          "that chat's background (\(identifier)) is not on this Mac yet"
            + (requested
              ? " — a download was requested; retry shortly"
              : ", and the Private API helper is not connected to fetch it")
        )
      }
    }

    /// Everything about the background except the bytes.
    ///
    /// Exists because the bytes route cannot carry any of it. `luminance` is the one a
    /// client actually needs — it is what Messages tints its own bubbles by, so a client
    /// rendering a transcript over this image needs it to keep text legible — and
    /// `available: false` with an identifier is how "set but not downloaded" is
    /// expressed as data rather than as a 404 string.
    registry.register(.chatBackgroundInfo) { request in
      let chat = try await Self.chatRow(request, context: context)
      switch TranscriptBackground.asset(for: chat.properties) {
      case .success(let asset):
        return .data(
          .object([
            "available": .bool(true),
            "identifier": .string(asset.identifier),
            "content_type": .string(asset.contentType),
            "byte_size": .int(asset.imageData.count),
            "luminance": asset.luminance.map(JSONValue.double) ?? .null,
            "is_high_key": asset.isHighKey.map(JSONValue.bool) ?? .null,
            "extension_identifier": asset.extensionIdentifier.map(JSONValue.string) ?? .null,
          ]))
      case .failure(.none):
        return .data(.object(["available": .bool(false), "identifier": .null]))
      case .failure(.notDownloaded(let identifier)):
        // `available: false` WITH an identifier is the "set but not here" case, which
        // a client can act on; `available: false` with a null identifier is "there is
        // no background", which it cannot.
        return .data(
          .object([
            "available": .bool(false), "identifier": .string(identifier),
          ]))
      }
    }

    /// Explicitly asking Messages to download a conversation's background.
    ///
    /// Separate from the implicit request the bytes route makes, because a client syncing
    /// several conversations wants to start every download and collect them later rather
    /// than hold a GET open for each.
    registry.register(.chatFetchBackground) { request in
      let chat = try await Self.chatRow(request, context: context)
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.refetchBackground(guid: chat.guid)

      // Waits only when asked, same as the bytes route: a client fetching several
      // conversations' wallpapers wants to start them all and collect later.
      var available = false
      let identifier = TranscriptBackground.identifier(in: chat.properties)
      if let identifier {
        available =
          await Self.waitForBackground(
            identifier: identifier, seconds: Self.requestedWait(request)
          ) != nil || TranscriptBackground.asset(identifier: identifier) != nil
      }
      return .data(
        .object([
          "requested": .bool(true),
          "identifier": identifier.map(JSONValue.string) ?? .null,
          "available": .bool(available),
        ]))
    }
  }

  /// Explicitly asking Messages to download a conversation's background.
  ///
  /// Separate from the implicit request the bytes route makes, because a client syncing
  /// several conversations wants to start the downloads and collect them later rather than
  /// hold a GET open for each.

  /// Asks the daemon for the asset. Reports whether the request was made at all — a server
  /// with no helper cannot fetch anything, and saying "retry shortly" there would be a lie.
  private static func requestBackgroundDownload(
    chatGUID: String, context: some InterfaceProviding & PrivateAPIProviding
  ) async -> Bool {
    guard let api = await context.privateAPIClient() else { return false }
    do {
      try await api.refetchChatBackground(chat: ChatGUID(chatGUID))
      return true
    } catch {
      // Not fatal to the request being served: the caller still gets an accurate 404,
      // and a failed fetch is not a failed read.
      return false
    }
  }

  /// How long the caller is willing to wait for a download, in seconds.
  ///
  /// Zero — the default — means "do not wait", which keeps the plain GET fast. Capped
  /// because the value arrives from a client and an unbounded wait is a held connection.
  static func requestedWait(_ request: APIRequestContext) -> Double {
    guard let raw = request.queryParameters["wait"], let seconds = Double(raw) else {
      return 0
    }
    return min(max(seconds, 0), 30)
  }

  /// Polls the cache for an asset that is being downloaded.
  ///
  /// Polling, because the arrival of the file is the only completion available: the daemon
  /// call returns immediately and `__kIMChatTranscriptBackgroundChangedNotification` is a
  /// rung-1 event the helper does not forward yet.
  static func waitForBackground(
    identifier: String, seconds: Double, interval: Duration = .milliseconds(250)
  ) async -> TranscriptBackground.Asset? {
    guard seconds > 0 else { return nil }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if let asset = TranscriptBackground.asset(identifier: identifier) { return asset }
      do { try await Task.sleep(for: interval) } catch { return nil }
    }
    return TranscriptBackground.asset(identifier: identifier)
  }

  /// The chat row behind a `:guid`, or the error that says which half is missing.
  private static func chatRow(
    _ request: APIRequestContext,
    context: some InterfaceProviding & PrivateAPIProviding
  ) async throws -> ChatRow {
    let guid = try request.requirePathParameter("guid")
    return try await context.requireInterfaces().chat.row(guid: guid)
  }

  // MARK: - Statistics

  private static func registerStatistics(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    registry.register(.serverStatMedia) { request in
      let interfaces = try await context.requireInterfaces()
      let wanted = Self.requestedCategories(request.queryParameters["only"])
      return .data(Self.totals(try await interfaces.attachment.mediaCounts(), only: wanted))
    }

    // NO `chatGuid` parameter, and the response is an ARRAY.
    //
    // Requiring one and answering with a single object would 400 a client calling the route
    // the way the reference defines it, with no parameters. Measured against a live Electron
    // server, which returns one entry per chat that has any media at all.
    registry.register(.serverStatMediaByChat) { request in
      let interfaces = try await context.requireInterfaces()
      let wanted = Self.requestedCategories(request.queryParameters["only"])
      let rows = try await interfaces.attachment.mediaCountsByChat()
      return .data(
        .array(
          rows.map { row in
            .object([
              "chatGuid": .string(row.guid),
              "groupName": row.displayName.map(JSONValue.string) ?? .null,
              "totals": Self.totals(row.counts, only: wanted),
            ])
          }))
    }
  }

  /// The three categories the wire names, in the reference's spelling.
  ///
  /// `audio`, `other` and a computed `total` were being returned as well. They are not in
  /// the reference's response and an added key fails the parity diff exactly as a missing
  /// one does — `getMediaTotals` builds its result from three `if` branches and has no
  /// fourth, so `other` is unreachable there even though its own default `only` list names
  /// it. That quirk is reproduced rather than tidied.
  private static let mediaCategories: [(singular: String, wire: String)] = [
    ("image", "images"), ("video", "videos"), ("location", "locations"),
  ]

  /// Parses `?only=images,videos`.
  ///
  /// The reference lower-cases each entry and strips ONE trailing `s`, so `images`, `image`
  /// and `Images` all mean the same thing. nil means every category.
  private static func requestedCategories(_ only: String?) -> Set<String>? {
    guard let only, !only.isEmpty else { return nil }
    let names = only.split(separator: ",").map { raw -> String in
      let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
      return trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
    }
    return Set(names)
  }

  /// Every requested bucket is present, including the zeroes.
  ///
  /// A client rendering three rows should not have to distinguish "no videos" from "the
  /// server forgot to mention videos" — and an omitted key reads as the latter.
  private static func totals(_ counts: [String: Int], only: Set<String>?) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for category in mediaCategories where only?.contains(category.singular) ?? true {
      object[category.wire] = .int(counts[category.singular] ?? 0)
    }
    return .object(object)
  }

  // MARK: - Nickname sharing
  //
  // Named `shareContact` on the wire. It shares the account's own contact card and
  // nickname with a chat, which IMCore calls nickname sharing.

  private static func registerNicknames(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    registry.register(.chatShouldShareContact) { request in
      let api = try await context.requirePrivateAPI(for: "contact sharing")
      let guid = try request.requirePathParameter("guid")
      let should = try await api.shouldOfferNicknameSharing(chat: ChatGUID(guid))
      return .data(.object(["shouldShare": .bool(should)]))
    }

    registry.register(.chatShareContact) { request in
      let api = try await context.requirePrivateAPI(for: "contact sharing")
      let guid = try request.requirePathParameter("guid")
      try await api.shareNickname(chat: ChatGUID(guid))
      return .data(nil)
    }
  }

  // MARK: - FindMy

  private static func registerFindMyDevices(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & PrivateAPIProviding
  ) {
    /// There is no way to make FindMy refresh its device cache from outside the app: the
    /// cache is written by FindMy itself, on its own schedule. Rather than pretend, this
    /// re-reads what is on disk and reports how old it is, so a client can tell a stale
    /// answer from a fresh one instead of trusting a refresh that did nothing.
    registry.register(.findmyRefreshDevices) { _ in
      let data = try FindMy.read(.devices)
      let modified =
        try? FileManager.default.attributesOfItem(
          atPath: FindMy.cacheDirectory.appendingPathComponent(
            FindMy.Cache.devices.rawValue
          ).path
        )[.modificationDate] as? Date

      return .data(
        try JSONValue.parse(data),
        metadata: .object([
          "cachedAt": modified.map { .int64(Int64($0.timeIntervalSince1970 * 1000)) } ?? .null,
          // Stated plainly: the server cannot make FindMy fetch.
          "refreshed": .bool(false),
        ])
      )
    }
  }

}
