//  GamePigeonCodecTests
//  The shuffle, against vectors computed independently, and the URL round-trip.
//
//  Every string here is synthetic. The format was measured against real Game Pigeon threads
//  (`docs/GAME_PIGEON.md`), but a fixture may not carry real message content, so the vectors
//  below were produced by a separate implementation of the same documented algorithm rather
//  than copied out of a conversation.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Game Pigeon codec")
struct GamePigeonCodecTests {

  @Test("The shuffle matches an independent implementation")
  func knownVectors() {
    let vectors = [
      ("?game=pool&player=1", "l=oe=ompplraa1&eg?y"),
      ("?a=1&b=2&c=3", "2b3==a1=c?&&"),
      (
        "?sender=SYNTH-0001&game=word&id=ABC123&player=2&start=",
        "lNo&en0BT3da=tga0y2rsa1=&w1iH&derCeS20rm=&red?t==Y-spA"
      ),
    ]
    for (plain, scrambled) in vectors {
      #expect(GamePigeonCodec.scramble(plain) == scrambled)
      #expect(GamePigeonCodec.unscramble(scrambled) == plain)
    }
  }

  @Test("Scrambling is a permutation and reverses at every length")
  func roundTrips() {
    for count in [0, 1, 2, 3, 17, 64, 561, 3309] {
      let plain = String(
        (0..<count).map { Array("abcdefghijklmnopqrstuvwxyz0123456789&=?")[$0 % 38] })
      let scrambled = GamePigeonCodec.scramble(plain)
      #expect(scrambled.count == plain.count)
      #expect(scrambled.sorted() == plain.sorted())
      #expect(GamePigeonCodec.unscramble(scrambled) == plain)
    }
  }

  @Test("A URL decodes to its fields, in order, and re-encodes to the same payload")
  func urlRoundTrip() {
    let payload = GamePigeonCodec.Payload(
      version: 52,
      fields: [
        ("sender", "SYNTH-0001"), ("game", "pool"), ("id", "ABC123"),
        ("player", "1"), ("start", ""), ("replay", "&d:0.5&x:1.25&balls:#3"),
      ])
    let url = GamePigeonCodec.encode(payload)
    #expect(url.hasPrefix("data:?ver=52&data="))
    let decoded = try! #require(GamePigeonCodec.decode(url: url))
    #expect(decoded == payload)
    #expect(decoded.game == "pool")
    #expect(decoded.gameID == "ABC123")
    // Order is preserved, because some games are positional about their fields.
    #expect(decoded.fields.map(\.name) == payload.fields.map(\.name))
    // An empty value is a real value: `start=` means something to Game Pigeon.
    #expect(decoded["start"] == "")
  }

  @Test("Anything that is not a Game Pigeon URL is nil, not a crash")
  func rejectsOtherPayloads() {
    #expect(GamePigeonCodec.decode(url: "data:,eyJ2ZXJzaW9uIjoxfQ==") == nil)
    #expect(GamePigeonCodec.decode(url: "https://example.com?ver=1&data=abc") == nil)
    #expect(GamePigeonCodec.decode(url: "data:?ver=52") == nil)
  }

  @Test("The extension is recognised by its bundle-id suffix, whatever the team id")
  func recognisesBundle() {
    let real =
      "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext"
    #expect(GamePigeonCodec.isGamePigeon(balloonBundleID: real))
    #expect(!GamePigeonCodec.isGamePigeon(balloonBundleID: nil))
    #expect(
      !GamePigeonCodec.isGamePigeon(
        balloonBundleID:
          "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls"))
  }
}
