//  ConversationLabelTests
//  How a conversation is named in the schedule composer's picker.
//
//  The fallback chain is the whole point of the feature and the part a screenshot cannot
//  prove: a name when the address book has one, the formatted number when it does not, and
//  the raw number preserved for search either way. A server with no contact access takes the
//  same path as a server whose address book simply misses an address — the map is empty, and
//  every row must still read exactly as it did before names existed.
//
//  The second half is which rows keep their address next to the name. A one-to-one chat does,
//  a group does not, and a chat whose name IS its address must not show it twice.
//
//  Search is here too, because the list shows one spelling of a conversation and people search
//  with the others — the pasted +1-number, the formatted one, the GUID out of a log.

import BBHandlers
import BBInterfaces
import BBSerialization
import BlueBubblesServerCore
import Foundation
import SwiftUI
import Testing

@testable import BlueBubblesApp

@Suite("Conversation labels")
struct ConversationLabelTests {

  private func chat(
    guid: String = "iMessage;-;+15550101234",
    displayName: String? = nil,
    participants: [String] = ["+15550101234"]
  ) -> ChatInterface.ChatSummary {
    ChatInterface.ChatSummary(
      guid: guid, displayName: displayName, participants: participants
    )
  }

  @Test("A known address is labelled with its contact name, address alongside")
  func namesAKnownAddress() {
    let label = ScheduleComposer.label(
      for: chat(), contactNames: ["+15550101234": "Aaron Bierlein"]
    )
    #expect(label.name == "Aaron Bierlein")
    #expect(label.address == "+1 (555) 010-1234")
    #expect(label.plain == "Aaron Bierlein  +1 (555) 010-1234")
  }

  @Test("An unknown address keeps the number it always showed, and shows it once")
  func fallsBackToTheFormattedNumber() {
    // Both the "no contacts at all" case — which is what a server without contact access
    // looks like from here — and the "contacts, but not this one" case. The address is
    // already the name here, so there is nothing to put after it.
    for names in [[:], ["+12025550199": "Someone Else"]] as [[String: String]] {
      let label = ScheduleComposer.label(for: chat(), contactNames: names)
      #expect(label.name == "+1 (555) 010-1234")
      #expect(label.address == nil)
      #expect(label.plain == "+1 (555) 010-1234")
    }
  }

  @Test("A group names the participants it can and leaves the rest as numbers")
  func namesGroupsPerParticipant() {
    // The mixed case is the one worth pinning: one miss must not cost the whole row its
    // names, which is what a chat-level all-or-nothing lookup would do.
    let label = ScheduleComposer.label(
      for: chat(
        guid: "iMessage;-;chat123",
        participants: ["+15550101234", "+15550105678"]
      ),
      contactNames: ["+15550101234": "Aaron Bierlein"]
    )
    #expect(label.name == "Aaron Bierlein, +1 (555) 010-5678")
    // No trailing address on a group: the participants are already the name, and a second
    // copy of them would double the length of the longest rows in the list.
    #expect(label.address == nil)
  }

  @Test("A named group keeps its own name")
  func displayNameWins() {
    // The chat's own title outranks the participants, named or not — it is what Messages
    // shows and what the user named the thread.
    let label = ScheduleComposer.label(
      for: chat(displayName: "Weekend Plans", participants: ["+15550101234", "+15550105678"]),
      contactNames: ["+15550101234": "Aaron Bierlein"]
    )
    #expect(label.name == "Weekend Plans")
    #expect(label.address == nil)
  }

  @Test("A one-to-one chat with its own title still shows the address")
  func namedDirectChatKeepsItsAddress() {
    // A one-participant chat that carries a display name is still a conversation with one
    // person, and the question "which number is this going to" has the same answer.
    let label = ScheduleComposer.label(for: chat(displayName: "Work"))
    #expect(label.name == "Work")
    #expect(label.address == "+1 (555) 010-1234")
  }

  // MARK: - Searching

  @Test("A row is found by name, by raw address, and by formatted address")
  func searchMatchesEverySpelling() throws {
    let choice = try #require(
      ScheduleComposer.choice(
        for: chat(), contactNames: ["+15550101234": "Aaron Bierlein"]
      )
    )

    // The name, which is the only one of these actually on screen.
    #expect(choice.matches("aaron"))
    #expect(choice.matches("BIERLEIN"))
    // The raw address, which is what a client's UI shows and what someone pastes.
    #expect(choice.matches("+15550101234"))
    // The formatted address, which is what the row shows next to the name.
    #expect(choice.matches("(555) 010-1234"))
    // The GUID, off screen entirely, but the thing a log line names.
    #expect(choice.matches("iMessage;-;"))

    #expect(!choice.matches("Kyle"))
    #expect(!choice.matches("2025550199"))
  }

  @Test("An unnamed conversation is still searchable by number")
  func searchWorksWithoutContacts() throws {
    // The no-contact-access case: no names to search by, so the numbers had better work.
    let choice = try #require(ScheduleComposer.choice(for: chat()))
    #expect(choice.matches("+15550101234"))
    #expect(choice.matches("555) 010"))
  }

  @Test("A chat with no usable GUID is not offered")
  func skipsChatsWithNoGUID() {
    // Nothing can be scheduled against it, so a row for it would be a dead end. A MISSING
    // guid is no longer representable — `ChatSummary.guid` is not optional — so what is
    // left to check is the empty one.
    #expect(ScheduleComposer.choice(for: chat(guid: "", displayName: "Ghost")) == nil)
  }

  @Test("Participants are what the lookup asks about")
  func addressesAreExtracted() {
    #expect(
      ScheduleComposer.addresses(
        in: chat(participants: ["+15550101234", "aaron@example.com"])
      ) == ["+15550101234", "aaron@example.com"]
    )
    // A chat that came back without participants asks about nothing rather than crashing
    // or inventing an address out of the GUID.
    #expect(ScheduleComposer.addresses(in: chat(participants: [])).isEmpty)
  }
}
