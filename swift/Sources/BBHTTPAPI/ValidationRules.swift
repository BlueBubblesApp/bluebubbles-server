//  ValidationRules
//  Which rules apply to which route. A transcription of `validators/*.ts`, keyed by handler.
//
//  KEYED BY HANDLER, NOT BY PATH
//  The reference attaches a validator per route in `httpRoutes.ts`, and routes that share a
//  controller share its validator: all four participant routes run `validateToggleParticipant`,
//  both download routes and blurhash run `validateDownload`. Keying on `HandlerID` reproduces
//  that grouping for free and makes it impossible to add a duplicate route (`RouteTable` has
//  several, deliberately) that silently escapes validation.
//
//  ORDER IS THE CONTRACT
//  Only the first failure is reported, in declaration order, so these arrays are transcribed
//  in the reference's own order and must not be sorted. `ValidationRuleParityTests` pins the
//  field names and their order against this file.
//
//  WHAT IS DELIBERATELY NOT HERE
//  The layer refuses what the reference refuses, and one field is knowingly left out because
//  reproducing it would mean reproducing a crash. `ValidationRuleParityTests` diffs this table
//  against a fixture generated from the reference and fails on any divergence not declared in
//  its `knowinglyDivergent` list, so the omission below is checked rather than trusted:
//
//    - `WebhookValidator.getWebhookRules` declares `id: "number"`, and `number` is not a
//      validatorjs rule. An unregistered rule THROWS (`rules.js:missedRuleValidator`), so the
//      reference answers 500 `Server Error` for any request that actually sends `id` — and
//      passes it through untouched when it does not, because an absent value is never
//      validatable. No working client sends it. Reproducing the 500 would be transcribing a
//      crash, so `id` carries no rule and `name` keeps its own.
//    - The bespoke checks that are not rule sets: `validateUpload`, `validateGroupChatIcon`,
//      the `parts` walk in `validateMultipart`, the send-method implications in
//      `validateText`, and every `ContactValidator` method. Those are handler logic, they
//      live in the handlers here too, and several already reproduce the reference's message.
//      This file covers the DECLARATIVE layer only.
//    - `where.*.args: "present"` is transcribed, but note what it does: `present` is satisfied
//      by an explicit `null`, so it only refuses a `where` element that omits `args` entirely.
//    - Routes with no validator in the reference get no entry. An absent entry means "the
//      reference validates nothing here", which is different from an empty rule set;
//      `ValidationRuleParityTests.everyValidatedRouteIsCovered` asserts the two lists agree.

import Foundation

public enum ValidationRules {

  /// Every reaction the reference accepts, from `MessageInterface.possibleReactions`. The
  /// leading-minus spellings are removals and are part of the same list.
  public static let reactions = [
    "love", "like", "dislike", "laugh", "emphasize", "question",
    "-love", "-like", "-dislike", "-laugh", "-emphasize", "-question",
  ]

  /// The rule set for a handler, or nil when the reference validates nothing.
  public static func ruleSet(for handler: HandlerID) -> ValidationRuleSet? {
    table[handler]
  }

  public static let table: [HandlerID: ValidationRuleSet] = [

    // MARK: alertsValidator.ts

    .serverMarkAlertRead: .init(
      .body,
      [
        .init("ids", [.required, .array])
      ]),

    // MARK: attachmentValidator.ts

    .attachmentFind: .init(
      .path,
      [
        .init("guid", [.required, .string])
      ]),

    // `downloadRules`, shared by three routes exactly as the reference shares it.
    .attachmentDownload: .init(.query, downloadRules),
    .attachmentForceDownload: .init(.query, downloadRules),
    .attachmentBlurhash: .init(.query, downloadRules),

    // MARK: chatValidator.ts

    .chatMessages: .init(
      .query,
      [
        .init("with", [.string]),
        // DESC before ASC here and ASC before DESC on `message/query`. Transcribed as written:
        // the order is invisible to `in`, and matching the source is what makes the two
        // readable as transcriptions rather than as a decision someone made.
        .init("sort", [.string, .inList(["DESC", "ASC"])]),
        .init("after", [.numeric, .min(0)]),
        .init("before", [.numeric, .min(1)]),
        .init("offset", [.numeric, .min(0)]),
        .init("limit", [.numeric, .min(1), .max(1000)]),
      ]),

    .chatQuery: .init(
      .body,
      [
        .init("with", [.array]),
        .init("sort", [.string, .inList(["lastmessage"])]),
        .init("offset", [.numeric, .min(0)]),
        .init("limit", [.numeric, .min(1), .max(1000)]),
      ]),

    .chatUpdate: .init(
      .body,
      [
        // No numeric rule, so `min:1` measures CHARACTERS and the message says so.
        .init("displayName", [.string, .min(1)])
      ]),

    .chatCreate: .init(
      .body,
      [
        .init("addresses", [.required, .array]),
        .init("message", [.string]),
        .init("method", [.string, .inList(["apple-script", "private-api"])]),
        .init("service", [.string, .inList(["iMessage", "SMS"])]),
        .init("tempGuid", [.string]),
        .init("effectId", [.string]),
        .init("subject", [.string]),
      ]),

    .chatAddParticipant: .init(.body, toggleParticipantRules),
    .chatRemoveParticipant: .init(.body, toggleParticipantRules),

    // MARK: fcmValidator.ts

    .fcmRegisterDevice: .init(
      .body,
      [
        .init("name", [.required, .string]),
        .init("identifier", [.required, .string]),
      ]),

    // MARK: handleValidator.ts

    .handleFind: .init(.path, handleFindRules),
    .handleFocusStatus: .init(.path, handleFindRules),

    .handleQuery: .init(
      .body,
      [
        .init("address", [.string]),
        .init("with", [.array]),
        .init("offset", [.numeric, .min(0)]),
        .init("limit", [.numeric, .min(1), .max(1000)]),
      ]),

    // `address: "string|required"` — `string` first, so a non-string address is refused as
    // "must be a string" rather than "is required". The reverse of every other rule set here,
    // and transcribed as written because the message differs.
    .handleIMessageAvailability: .init(.query, availabilityRules),
    .handleFaceTimeAvailability: .init(.query, availabilityRules),

    // MARK: messageValidator.ts

    .messageCount: .init(
      .query,
      [
        .init("chatGuid", [.string]),
        .init("after", [.numeric, .min(0)]),
        .init("before", [.numeric, .min(1)]),
        .init("minRowId", [.numeric, .min(0)]),
        .init("maxRowId", [.numeric, .min(1)]),
      ]),

    // The one rule set with a recorded 400 fixture behind it
    // (`get_api_v1_message_count_updated-5baa61-400.json`): `after` is REQUIRED here and
    // optional on `count`, which looked like a route where this server was wrongly strict
    // until the validator turned up.
    .messageCountUpdated: .init(
      .query,
      [
        .init("chatGuid", [.string]),
        .init("after", [.required, .numeric, .min(0)]),
        .init("before", [.numeric, .min(1)]),
        .init("minRowId", [.numeric, .min(0)]),
        .init("maxRowId", [.numeric, .min(1)]),
      ]),

    .messageFind: .init(
      .path,
      [
        .init("guid", [.required, .string])
      ]),

    .messageQuery: .init(
      .body,
      [
        .init("with", [.array]),
        .init("convertAttachments", [.boolean]),
        .init("where", [.array]),
        .init("where.*.statement", [.required, .string]),
        .init("where.*.args", [.present]),
        .init("sort", [.string, .inList(["ASC", "DESC"])]),
        .init("after", [.numeric, .min(0)]),
        .init("before", [.numeric, .min(1)]),
        .init("chatGuid", [.string]),
        .init("offset", [.numeric, .min(0)]),
        // The fixture: `{"limit": "not-a-number"}` → "The limit must be a number."
        .init("limit", [.numeric, .min(1), .max(1000)]),
      ]),

    .messageSendText: .init(
      .body,
      [
        .init("chatGuid", [.required, .string]),
        .init("tempGuid", [.string]),
        // `present|string`, not `required`: an explicit null message is accepted here and
        // refused later by the send-method check, which is a different 400 with a different
        // sentence. Omitting the key entirely is what this refuses.
        .init("message", [.present, .string]),
        .init("method", [.string, .inList(["apple-script", "private-api"])]),
        .init("effectId", [.string]),
        .init("subject", [.string]),
        .init("selectedMessageGuid", [.string]),
        .init("partIndex", [.numeric, .min(0)]),
        .init("ddScan", [.boolean]),
        .init("textFormatting", [.array]),
      ]),

    .messageSendAttachment: .init(
      .body,
      [
        .init("chatGuid", [.required, .string]),
        .init("tempGuid", [.string]),
        .init("method", [.string, .inList(["apple-script", "private-api"])]),
        .init("name", [.required, .string]),
        .init("isAudioMessage", [.boolean]),
        .init("effectId", [.string]),
        .init("subject", [.string]),
        .init("selectedMessageGuid", [.string]),
        .init("partIndex", [.numeric, .min(0)]),
      ]),

    .messageReact: .init(
      .body,
      [
        .init("chatGuid", [.required, .string]),
        .init("selectedMessageGuid", [.required, .string]),
        .init("reaction", [.required, .string, .inList(reactions)]),
        .init("partIndex", [.numeric, .min(0)]),
      ]),

    .messageEdit: .init(
      .body,
      [
        .init("editedMessage", [.required, .string]),
        .init("backwardsCompatibilityMessage", [.required, .string]),
        .init("partIndex", [.numeric, .min(0)]),
      ]),

    .messageUnsend: .init(
      .body,
      [
        .init("partIndex", [.numeric, .min(0)])
      ]),

    .messageEmbeddedMedia: .init(
      .path,
      [
        .init("guid", [.required, .string])
      ]),

    .messageSendMultipart: .init(
      .body,
      [
        .init("chatGuid", [.required, .string]),
        .init("tempGuid", [.string]),
        .init("effectId", [.string]),
        .init("subject", [.string]),
        .init("selectedMessageGuid", [.string]),
        .init("partIndex", [.numeric, .min(0)]),
        .init("parts", [.required, .array]),
        .init("ddScan", [.boolean]),
      ]),

    .messageSendAttachmentChunk: .init(
      .body,
      [
        .init("chatGuid", [.required, .string]),
        .init("attachmentGuid", [.required, .string]),
        .init("name", [.required, .string]),
        .init("chunkIndex", [.required, .numeric, .min(0)]),
        .init("totalChunks", [.required, .numeric, .min(1)]),
        .init("isComplete", [.boolean]),
        .init("method", [.string, .inList(["apple-script", "private-api"])]),
        .init("isAudioMessage", [.boolean]),
        .init("effectId", [.string]),
        .init("subject", [.string]),
        .init("selectedMessageGuid", [.string]),
        .init("partIndex", [.numeric, .min(0)]),
      ]),

    // MARK: scheduledMessageValidator.ts

    // `type: "string|in:send-message|required"` splits on `|` into three rules, so the `in`
    // list holds one entry and `required` runs last. Transcribed with that order.
    .scheduleCreate: .init(.body, scheduledMessageRules),
    .scheduleUpdate: .init(.body, scheduledMessageRules),

    // MARK: settingsValidator.ts / themeValidator.ts

    .backupCreateSettings: .init(.body, namedBackupRules),
    .backupCreateTheme: .init(.body, namedBackupRules),
    .backupDeleteSettings: .init(.body, namedBackupDeleteRules),
    .backupDeleteTheme: .init(.body, namedBackupDeleteRules),

    // MARK: webhookValidator.ts

    // `id: "number"` is omitted; see the file header.
    .webhookList: .init(
      .query,
      [
        .init("name", [.string])
      ]),

    .webhookCreate: .init(
      .body,
      [
        .init("url", [.required, .string]),
        .init("events", [.required, .array]),
      ]),
  ]

  // MARK: - Shared sets
  //
  // Named where the reference shares one object between routes, so the sharing is visible
  // here too rather than being two transcriptions that have to be kept in step by hand.

  private static let downloadRules: [FieldValidation] = [
    .init("height", [.numeric, .min(1)]),
    .init("width", [.numeric, .min(1)]),
    .init("quality", [.string, .inList(["good", "better", "best"])]),
    .init("force", [.boolean]),
    .init("original", [.boolean]),
  ]

  private static let toggleParticipantRules: [FieldValidation] = [
    .init("address", [.required, .string])
  ]

  private static let handleFindRules: [FieldValidation] = [
    .init("guid", [.required, .string])
  ]

  private static let availabilityRules: [FieldValidation] = [
    .init("address", [.string, .required])
  ]

  private static let scheduledMessageRules: [FieldValidation] = [
    .init("type", [.string, .inList(["send-message"]), .required]),
    .init("payload", [.jsonObject, .required]),
    .init("scheduledFor", [.numeric, .min(1), .required]),
    .init("schedule", [.jsonObject, .required]),
  ]

  private static let namedBackupRules: [FieldValidation] = [
    .init("name", [.required, .string, .min(3), .max(50)]),
    .init("data", [.required]),
  ]

  private static let namedBackupDeleteRules: [FieldValidation] = [
    .init("name", [.required, .string, .min(3), .max(50)])
  ]
}
