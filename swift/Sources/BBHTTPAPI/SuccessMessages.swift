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
    "general.ping": "Ping received!",

    // macOS
    "mac.lock": "Successfully executed lock command!",
    "mac.restartMessages": "Successfully restart the Messages App!",

    // iCloud
    "icloud.accountInfo": "Successfully fetched account info!",
    "icloud.contactCard": "Successfully fetched contact card!",
    "icloud.contactCardV2": "Successfully fetched contact card!",
    "icloud.changeAlias": "Successfully changed iMessage Alias!",

    // FindMy
    "findmy.devices": "Successfully fetched Find My device locations!",
    "findmy.friends": "Successfully fetched Find My friends locations!",
    "findmy.refreshDevices": "Successfully refreshed Find My device locations!",
    "findmy.refreshFriends": "Successfully refreshed Find My friends locations!",

    // Messages
    "message.query": "Successfully fetched messages!",
    "message.sendText": "Message sent!",
    "message.sendAttachment": "Attachment sent!",
    "message.sendMultipart": "Message sent!",
    "message.sendAttachmentChunk": "Attachment sent!",
    "message.react": "Reaction sent!",
    "message.unsend": "Message unsent!",
    "message.edit": "Message edited!",

    // Chats
    "chat.create": "Successfully created chat!",
    "chat.markRead": "Successfully marked chat as read!",
    "chat.markUnread": "Successfully marked chat as unread!",
    "chat.setGroupIcon": "Successfully set group chat icon!",
    "chat.removeGroupIcon": "Successfully removed group chat icon!",

    // Scheduled messages
    "schedule.create": "Successfully created new scheduled message!",
    "schedule.update": "Successfully updated the scheduled message!",
    "schedule.delete": "Successfully deleted scheduled message!",

    // Webhooks
    "webhook.list": "Successfully fetched webhooks!",
    "webhook.create": "Successfully created webhook!",
    "webhook.update": "Successfully updated webhook!",
    "webhook.delete": "Successfully deleted webhook!",

    // Backups
    "backup.getSettings": "Successfully fetched settings!",
    "backup.createSettings": "Successfully saved settings!",
    "backup.deleteSettings": "Successfully deleted settings!",
    "backup.getTheme": "Successfully fetched theme(s)!",
    "backup.createTheme": "Successfully saved theme!",
    "backup.deleteTheme": "Successfully deleted theme!",

    // FCM
    "fcm.registerDevice": "Successfully added device!",

    // Server lifecycle
    "server.restartServices": "Successfully kicked off services restart!",
    "server.restartAll": "Successfully kicked off re-launch process!",
  ]

  /// The message for a route, or nil to use the default.
  public static func message(for handler: HandlerID) -> String? {
    byHandler[handler]
  }
}
