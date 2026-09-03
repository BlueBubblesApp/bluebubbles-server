//  AppBalloonRefusalTests
//  `POST /api/v2/message/app` refuses a balloon it cannot build properly.
//
//  This route is generic on purpose — a bundle id and a payload it does not read — which is
//  right for a third-party app and wrong for one this server builds elsewhere. It writes a
//  TEMPLATE layout, and a poll needs a LIVE layout, so a poll sent from here renders as
//  "Sent a poll" with no options no matter what its payload says. It failed silently, into
//  a real conversation, twice.

import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("App balloon refusal")
struct AppBalloonRefusalTests {

  /// The shape a real poll payload has, so the tests below differ from it deliberately.
  private var validPollJSON: JSONValue {
    .object([
      "version": .int(1),
      "item": .object([
        "orderedPollOptions": .array([
          .object([
            "text": .string("Red"),
            "attributedText": .string("Red"),
            "optionIdentifier": .string("BB650E75-8A00-4578-BA3B-098E22C50B56"),
            "canBeEdited": .bool(false),
          ])
        ])
      ]),
    ])
  }

  @Test("An ordinary app balloon is not refused")
  func otherBalloonsPass() {
    // The route has to stay generic. Refusing anything but the balloons we build ourselves
    // would break every third-party app, which is the whole point of the route.
    #expect(
      MessageInterface.refusal(
        forBalloon:
          "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ"
          + ":com.gamerdelights.gamepigeon.ext",
        payload: .fields([("game", "pool")])
      ) == nil)
    #expect(
      MessageInterface.refusal(forBalloon: "com.example.SomeApp", payload: .url("data:?a=1"))
        == nil)
  }

  @Test("The Polls balloon is refused even with a well-formed payload")
  func pollsAreAlwaysRefused() {
    // The layout, not the payload, is what makes it broken — so a correct payload must be
    // refused too. This is the case that would otherwise look like it works.
    let refusal = MessageInterface.refusal(
      forBalloon: PollsApp.balloonBundleID, payload: .json(validPollJSON))
    #expect(refusal != nil)
    // It names the route that DOES work. An error that only says "no" leaves a client
    // author with nowhere to go.
    #expect(refusal?.contains("POST /api/v2/message/poll") == true)
    #expect(refusal?.contains("live layout") == true)
    // And it does not claim the payload was the problem, because it was not.
    #expect(refusal?.contains("also not a poll") == false)
  }

  @Test("A malformed poll payload is named as well as refused")
  func malformedPayloadsAreDiagnosed() {
    // Both facts, not one: fixing the payload would not make this route work, and a client
    // that only heard about the layout would fix the route and hit a second wall.
    let refusal = MessageInterface.refusal(
      forBalloon: PollsApp.balloonBundleID,
      payload: .json(.object(["version": .int(1), "item": .object([:])]))
    )
    #expect(refusal?.contains("also not a poll") == true)
    #expect(refusal?.contains("orderedPollOptions") == true)
  }

  @Test("A payload that is not JSON at all is reported as such")
  func nonJSONPayloadsAreExplained() {
    // This is what the two balloons in the real conversation were: the `fields` and `json`
    // encoders being exercised against the Polls bundle id.
    for payload in [
      MessageInterface.AppPayload.fields([("a", "1")]),
      MessageInterface.AppPayload.url("data:?a=1"),
    ] {
      let refusal = MessageInterface.refusal(
        forBalloon: PollsApp.balloonBundleID, payload: payload)
      #expect(refusal?.contains("base64 JSON") == true)
    }
  }

  @Test("Each missing option field is named individually")
  func everyMissingFieldIsNamed() {
    // A client fixing one field at a time against a generic "invalid payload" is a bad
    // afternoon. The index is included because a poll has several options.
    let payload = MessageInterface.AppPayload.json(
      .object([
        "version": .int(1),
        "item": .object([
          "orderedPollOptions": .array([
            .object(["text": .string("Red"), "optionIdentifier": .string("OK")]),
            .object(["text": .string("")]),
          ])
        ]),
      ]))
    #expect(payload.missingPollFields.contains("`item.orderedPollOptions[1].text`"))
    #expect(payload.missingPollFields.contains("`item.orderedPollOptions[1].optionIdentifier`"))
    // The option that IS complete is not reported.
    #expect(!payload.missingPollFields.contains("`item.orderedPollOptions[0].text`"))
  }

  @Test("A vote payload counts as a poll shape")
  func votePayloadsAreRecognised() {
    // A poll's payload is one of two shapes — the definition or a vote — and reporting a
    // vote as "missing orderedPollOptions" would be wrong.
    let vote = MessageInterface.AppPayload.json(
      .object([
        "version": .int(1),
        "item": .object([
          "votes": .array([
            .object([
              "participantHandle": .string("e:someone@example.com"),
              "voteOptionIdentifier": .string("9A8944AF-9941-494C-808A-11D9D76F27BC"),
            ])
          ])
        ]),
      ]))
    #expect(vote.missingPollFields.isEmpty)
  }
}
