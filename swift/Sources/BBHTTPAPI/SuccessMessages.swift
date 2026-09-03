//  SuccessMessages
//  The envelope's `message` field, per route.
//
//  `{status, message, data?, metadata?}` — and `message` is not decorative. About forty of the
//  reference's routes pass their own string to `new Success(...)`; the rest fall through to
//  `ResponseMessages.SUCCESS`. This server answered "Success" everywhere, so `GET /ping`
//  returned `"Success"` where every client that has ever talked to a BlueBubbles server got
//  `"Ping received!"`.
//
//  Found by diffing a live Electron server, not by reading the code — the strings are spread
//  across thirteen router files and none of them is remarkable on its own.
//
//  A table rather than an argument at forty call sites, for two reasons: the strings are data
//  transcribed from another codebase and belong somewhere they can be reviewed against it in
//  one screen, and a handler that forgets to pass one degrades to "Success" silently, which is
//  exactly the failure being fixed. `SuccessMessageTests` asserts the table against an
//  independent transcription.
//
//  Routes whose message is CONDITIONAL — `themeRouter.get` says "No saved themes!" when the
//  list is empty and "Successfully fetched theme(s)!" when it is not — are not in this table.
//  They pass `message:` on the result themselves, because only the handler knows which case
//  it is in.
//
//  See `.claude/docs/api.md`.

import Foundation

public enum SuccessMessages {

  /// Handler ID to envelope message. Absent means "Success".
  ///
  /// Transcribed from the `new Success(ctx, { message: … })` calls in
  /// `packages/server/src/server/api/http/api/v1/routers/*.ts`. The oddities are the
  /// reference's own and are deliberate: "Successfully restart the Messages App!" is
  /// ungrammatical, and "Successfully fetched theme(s)!" carries the parenthetical. Both are
  /// what clients receive today.
  static let byHandler: [HandlerID: String] = [
    // general
    .generalPing: "Ping received!",

    // macOS
    .macLock: "Successfully executed lock command!",
    .macRestartMessages: "Successfully restart the Messages App!",

    // iCloud
    .icloudAccountInfo: "Successfully fetched account info!",
    .icloudContactCard: "Successfully fetched contact card!",
    .icloudContactCardV2: "Successfully fetched contact card!",
    .icloudChangeAlias: "Successfully changed iMessage Alias!",

    // FindMy
    .findmyDevices: "Successfully fetched Find My device locations!",
    .findmyFriends: "Successfully fetched Find My friends locations!",
    .findmyRefreshDevices: "Successfully refreshed Find My device locations!",
    .findmyRefreshFriends: "Successfully refreshed Find My friends locations!",

    // Messages
    .messageQuery: "Successfully fetched messages!",
    .messageSendText: "Message sent!",
    .messageSendAttachment: "Attachment sent!",
    .messageSendMultipart: "Message sent!",
    .messageSendAttachmentChunk: "Attachment sent!",
    .messageReact: "Reaction sent!",
    .messageSendSticker: "Sticker sent!",
    .messageSendLater: "Message scheduled!",
    .messageCancelScheduled: "Scheduled message cancelled!",
    .messagePoll: "Successfully fetched poll!",
    .messageCreatePoll: "Poll sent!",
    .messageVotePoll: "Vote sent!",
    .messageAddPollOption: "Poll choice added!",
    .messageUnsend: "Message unsent!",
    .messageEdit: "Message edited!",

    // Chats
    .chatCreate: "Successfully created chat!",
    .chatMarkRead: "Successfully marked chat as read!",
    .chatMarkUnread: "Successfully marked chat as unread!",
    .chatSetGroupIcon: "Successfully set group chat icon!",
    .chatRemoveGroupIcon: "Successfully removed group chat icon!",

    // Scheduled messages
    .scheduleCreate: "Successfully created new scheduled message!",
    .scheduleUpdate: "Successfully updated the scheduled message!",
    .scheduleDelete: "Successfully deleted scheduled message!",

    // Webhooks
    .webhookList: "Successfully fetched webhooks!",
    .webhookCreate: "Successfully created webhook!",
    .webhookUpdate: "Successfully updated webhook!",
    .webhookDelete: "Successfully deleted webhook!",

    // Backups
    .backupGetSettings: "Successfully fetched settings!",
    .backupCreateSettings: "Successfully saved settings!",
    .backupDeleteSettings: "Successfully deleted settings!",
    .backupGetTheme: "Successfully fetched theme(s)!",
    .backupCreateTheme: "Successfully saved theme!",
    .backupDeleteTheme: "Successfully deleted theme!",

    // FCM
    .fcmRegisterDevice: "Successfully added device!",

    // Server lifecycle
    .serverRestartServices: "Successfully kicked off services restart!",
    .serverRestartAll: "Successfully kicked off re-launch process!",
  ]

  /// The message for a route, or nil to use the default.
  public static func message(for handler: HandlerID) -> String? {
    byHandler[handler]
  }
}
