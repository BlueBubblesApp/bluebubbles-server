//  HandlerIDs
//  Every handler identifier, declared once.
//
//  `HandlerID` is deliberately NOT `ExpressibleByStringLiteral`. With that conformance the
//  route table writes `"message.query"` and the controller registers `"message.query"` with
//  nothing connecting the two: a typo on either side compiles cleanly and produces a route
//  with no controller — caught, but at MOUNT time, by `HandlerRegistry.missing(for:)`, and
//  only for the half that the table names. A handler registered under a misspelling nothing
//  references is simply never called.
//
//  Declaring them here as plain values moves that to the compiler. The route table still imports nothing from the controllers — these are plain
//  values in this module — so it remains the pure description that a test can read without
//  standing up a server, which is the property the string form was protecting.
//
//  The RAW VALUES are a client contract and must never change: they key `SuccessMessages`,
//  the OpenAPI query-parameter table, and the parity fixtures. Renaming a constant is free;
//  changing the string it holds is not.
//
//  See `.claude/docs/api.md`.

extension HandlerID {

  // MARK: - attachment
  public static let attachmentBlurhash = HandlerID("attachment.blurhash")
  public static let attachmentCount = HandlerID("attachment.count")
  public static let attachmentDownload = HandlerID("attachment.download")
  public static let attachmentDownloadLive = HandlerID("attachment.downloadLive")
  public static let attachmentFind = HandlerID("attachment.find")
  public static let attachmentForceDownload = HandlerID("attachment.forceDownload")
  public static let attachmentUpload = HandlerID("attachment.upload")

  // MARK: - auth
  public static let authRegister = HandlerID("auth.register")
  public static let authRevoke = HandlerID("auth.revoke")
  public static let authRotate = HandlerID("auth.rotate")
  public static let authToken = HandlerID("auth.token")

  // MARK: - backup
  public static let backupCreateSettings = HandlerID("backup.createSettings")
  public static let backupCreateTheme = HandlerID("backup.createTheme")
  public static let backupDeleteSettings = HandlerID("backup.deleteSettings")
  public static let backupDeleteTheme = HandlerID("backup.deleteTheme")
  public static let backupGetSettings = HandlerID("backup.getSettings")
  public static let backupGetTheme = HandlerID("backup.getTheme")

  // MARK: - chat
  public static let chatAddParticipant = HandlerID("chat.addParticipant")
  public static let chatBackground = HandlerID("chat.background")
  public static let chatBackgroundInfo = HandlerID("chat.backgroundInfo")
  public static let chatClearHistory = HandlerID("chat.clearHistory")
  public static let chatCount = HandlerID("chat.count")
  public static let chatCreate = HandlerID("chat.create")
  public static let chatDelete = HandlerID("chat.delete")
  public static let chatDeleteMessage = HandlerID("chat.deleteMessage")
  public static let chatFetchBackground = HandlerID("chat.fetchBackground")
  public static let chatFilterState = HandlerID("chat.filterState")
  public static let chatFind = HandlerID("chat.find")
  public static let chatGroupIcon = HandlerID("chat.groupIcon")
  public static let chatLeave = HandlerID("chat.leave")
  public static let chatMarkKnown = HandlerID("chat.markKnown")
  public static let chatMarkRead = HandlerID("chat.markRead")
  public static let chatMarkSpam = HandlerID("chat.markSpam")
  public static let chatMarkUnread = HandlerID("chat.markUnread")
  public static let chatMessages = HandlerID("chat.messages")
  public static let chatMute = HandlerID("chat.mute")
  public static let chatMuteState = HandlerID("chat.muteState")
  public static let chatPin = HandlerID("chat.pin")
  public static let chatPinned = HandlerID("chat.pinned")
  public static let chatQuery = HandlerID("chat.query")
  public static let chatRemoveGroupIcon = HandlerID("chat.removeGroupIcon")
  public static let chatRemoveParticipant = HandlerID("chat.removeParticipant")
  public static let chatReportJunk = HandlerID("chat.reportJunk")
  public static let chatSetFilter = HandlerID("chat.setFilter")
  public static let chatSetGroupIcon = HandlerID("chat.setGroupIcon")
  public static let chatShareContact = HandlerID("chat.shareContact")
  public static let chatShouldShareContact = HandlerID("chat.shouldShareContact")
  public static let chatStartTyping = HandlerID("chat.startTyping")
  public static let chatStopTyping = HandlerID("chat.stopTyping")
  public static let chatUnmute = HandlerID("chat.unmute")
  public static let chatUnpin = HandlerID("chat.unpin")
  public static let chatUpdate = HandlerID("chat.update")

  // MARK: - contact
  public static let contactAvatar = HandlerID("contact.avatar")
  public static let contactCreate = HandlerID("contact.create")
  public static let contactDelete = HandlerID("contact.delete")
  public static let contactFindByExternalID = HandlerID("contact.findByExternalID")
  public static let contactImportVCF = HandlerID("contact.importVCF")
  public static let contactList = HandlerID("contact.list")
  public static let contactQuery = HandlerID("contact.query")
  public static let contactUpdate = HandlerID("contact.update")

  // MARK: - facetime
  public static let facetimeAdmit = HandlerID("facetime.admit")
  public static let facetimeAnswer = HandlerID("facetime.answer")
  public static let facetimeCall = HandlerID("facetime.call")
  public static let facetimeCleanup = HandlerID("facetime.cleanup")
  public static let facetimeDebug = HandlerID("facetime.debug")
  public static let facetimeDismissAlert = HandlerID("facetime.dismissAlert")
  public static let facetimeGenerateLink = HandlerID("facetime.generateLink")
  public static let facetimeHandoff = HandlerID("facetime.handoff")
  public static let facetimeInvalidateLinks = HandlerID("facetime.invalidateLinks")
  public static let facetimeLeave = HandlerID("facetime.leave")
  public static let facetimeLeaveCall = HandlerID("facetime.leaveCall")
  public static let facetimeMembers = HandlerID("facetime.members")
  public static let facetimeNewSession = HandlerID("facetime.newSession")
  public static let facetimeRecents = HandlerID("facetime.recents")
  public static let facetimeRestart = HandlerID("facetime.restart")
  public static let facetimeWindows = HandlerID("facetime.windows")

  // MARK: - fcm
  public static let fcmClientConfig = HandlerID("fcm.clientConfig")
  public static let fcmRegisterDevice = HandlerID("fcm.registerDevice")

  // MARK: - findmy
  public static let findmyDevices = HandlerID("findmy.devices")
  public static let findmyFriends = HandlerID("findmy.friends")
  public static let findmyRefreshDevices = HandlerID("findmy.refreshDevices")
  public static let findmyRefreshFriend = HandlerID("findmy.refreshFriend")
  public static let findmyRefreshFriends = HandlerID("findmy.refreshFriends")
  public static let findmyRequestShare = HandlerID("findmy.requestShare")
  public static let findmyStartSharing = HandlerID("findmy.startSharing")
  public static let findmyStatus = HandlerID("findmy.status")
  public static let findmyStopSharing = HandlerID("findmy.stopSharing")

  // MARK: - general
  public static let generalPing = HandlerID("general.ping")

  // MARK: - handle
  public static let handleCount = HandlerID("handle.count")
  public static let handleFaceTimeAvailability = HandlerID("handle.faceTimeAvailability")
  public static let handleFind = HandlerID("handle.find")
  public static let handleFocusStatus = HandlerID("handle.focusStatus")
  public static let handleIMessageAvailability = HandlerID("handle.iMessageAvailability")
  public static let handleQuery = HandlerID("handle.query")

  // MARK: - icloud
  public static let icloudAccountInfo = HandlerID("icloud.accountInfo")
  public static let icloudChangeAlias = HandlerID("icloud.changeAlias")
  public static let icloudContactCard = HandlerID("icloud.contactCard")
  public static let icloudContactCardV2 = HandlerID("icloud.contactCardV2")

  // MARK: - mac
  public static let macLock = HandlerID("mac.lock")
  public static let macRestartMessages = HandlerID("mac.restartMessages")

  // MARK: - message
  public static let messageCount = HandlerID("message.count")
  public static let messageCountUpdated = HandlerID("message.countUpdated")
  public static let messageEdit = HandlerID("message.edit")
  public static let messageEmbeddedMedia = HandlerID("message.embeddedMedia")
  public static let messageFind = HandlerID("message.find")
  public static let messageHydrate = HandlerID("message.hydrate")
  public static let messageNotify = HandlerID("message.notify")
  public static let messageQuery = HandlerID("message.query")
  public static let messageReact = HandlerID("message.react")
  public static let messageSendAttachment = HandlerID("message.sendAttachment")
  public static let messageSendAttachmentChunk = HandlerID("message.sendAttachmentChunk")
  public static let messageSendMultipart = HandlerID("message.sendMultipart")
  public static let messageSendSticker = HandlerID("message.sendSticker")
  public static let messageSendLater = HandlerID("message.sendLater")
  public static let messageCancelScheduled = HandlerID("message.cancelScheduled")
  public static let messagePendingScheduled = HandlerID("message.pendingScheduled")
  public static let messageReschedule = HandlerID("message.reschedule")
  public static let messageSendScheduledNow = HandlerID("message.sendScheduledNow")
  public static let messagePoll = HandlerID("message.poll")
  public static let messageCreatePoll = HandlerID("message.createPoll")
  public static let messageVotePoll = HandlerID("message.votePoll")
  public static let messageAddPollOption = HandlerID("message.addPollOption")
  public static let messageSendText = HandlerID("message.sendText")
  public static let messageSentCount = HandlerID("message.sentCount")
  public static let messageUnsend = HandlerID("message.unsend")

  // MARK: - schedule
  public static let scheduleCreate = HandlerID("schedule.create")
  public static let scheduleDelete = HandlerID("schedule.delete")
  public static let scheduleFind = HandlerID("schedule.find")
  public static let scheduleList = HandlerID("schedule.list")
  public static let scheduleUpdate = HandlerID("schedule.update")

  // MARK: - security
  public static let securityAllow = HandlerID("security.allow")
  public static let securityClearBlocked = HandlerID("security.clearBlocked")
  public static let securityDisallow = HandlerID("security.disallow")
  public static let securityListAllowed = HandlerID("security.listAllowed")
  public static let securityListBlocked = HandlerID("security.listBlocked")
  public static let securityRecentFailures = HandlerID("security.recentFailures")
  public static let securityUnblock = HandlerID("security.unblock")

  // MARK: - server
  public static let serverAlerts = HandlerID("server.alerts")
  public static let serverAlertsV2 = HandlerID("server.alertsV2")
  public static let serverCheckUpdate = HandlerID("server.checkUpdate")
  public static let serverInfo = HandlerID("server.info")
  public static let serverInstallUpdate = HandlerID("server.installUpdate")
  public static let serverLogs = HandlerID("server.logs")
  public static let serverMarkAlertRead = HandlerID("server.markAlertRead")
  public static let serverMarkAlertReadV2 = HandlerID("server.markAlertReadV2")
  public static let serverRestartAll = HandlerID("server.restartAll")
  public static let serverRestartServices = HandlerID("server.restartServices")
  public static let serverStatMedia = HandlerID("server.statMedia")
  public static let serverStatMediaByChat = HandlerID("server.statMediaByChat")
  public static let serverStatTotals = HandlerID("server.statTotals")

  // MARK: - ui
  public static let uiIndex = HandlerID("ui.index")

  // MARK: - webhook
  public static let webhookCreate = HandlerID("webhook.create")
  public static let webhookDelete = HandlerID("webhook.delete")
  public static let webhookList = HandlerID("webhook.list")
  public static let webhookUpdate = HandlerID("webhook.update")
}
