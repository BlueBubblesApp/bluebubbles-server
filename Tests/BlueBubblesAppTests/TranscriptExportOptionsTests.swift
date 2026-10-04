//  TranscriptExportOptionsTests
//  The export page's decisions, which live off the view so they can be stated here.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBInterfaces
import BBTranscript
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Transcript export options")
struct TranscriptExportOptionsTests {

  private func candidate(
    _ guid: String, title: String? = nil, addresses: [String], names: [String?] = []
  ) -> TranscriptInterface.ChatCandidate {
    let participants = addresses.enumerated().map { index, address in
      Transcript.Participant(
        address: address, name: index < names.count ? names[index] : nil,
        nameSource: index < names.count && names[index] != nil ? .contacts : .none)
    }
    return TranscriptInterface.ChatCandidate(
      chat: Transcript.Chat(
        guid: guid, displayName: title, isGroup: addresses.count > 1,
        participants: participants),
      lastMessageDate: nil, isArchived: false)
  }

  private var three: [TranscriptInterface.ChatCandidate] {
    [
      candidate(
        "iMessage;-;+12025550143", addresses: ["+12025550143"], names: ["Alice Example"]),
      candidate(
        "iMessage;+;chat1", title: "Weekend Plans",
        addresses: ["+12025550144", "a@example.com"]),
      candidate("iMessage;-;b@example.com", addresses: ["b@example.com"]),
    ]
  }

  // MARK: Searching

  @Test("An empty or whitespace query admits everything")
  func emptyQuery() {
    #expect(TranscriptChatFilter.filter(three, query: "").count == 3)
    #expect(TranscriptChatFilter.filter(three, query: "   ").count == 3)
  }

  @Test("A name, a title, an address and a run of digits each find their conversation")
  func matching() {
    #expect(TranscriptChatFilter.filter(three, query: "alice").map(\.id) == [three[0].id])
    #expect(TranscriptChatFilter.filter(three, query: "weekend").map(\.id) == [three[1].id])
    #expect(TranscriptChatFilter.filter(three, query: "b@example").map(\.id) == [three[2].id])
    #expect(TranscriptChatFilter.filter(three, query: "555 0144").map(\.id) == [three[1].id])
    let punctuated = TranscriptChatFilter.filter(three, query: "(202) 555-0143")
    #expect(punctuated.map(\.id) == [three[0].id])
    #expect(TranscriptChatFilter.filter(three, query: "zzz").isEmpty)
  }

  @Test("Arrow keys enter from the end pressed towards and clamp at the ends")
  func arrows() {
    #expect(TranscriptChatFilter.selection(movedBy: 1, in: three, from: "") == three[0].id)
    #expect(TranscriptChatFilter.selection(movedBy: -1, in: three, from: "") == three[2].id)
    let last = three[2].id
    #expect(TranscriptChatFilter.selection(movedBy: 1, in: three, from: last) == last)
    let up = TranscriptChatFilter.selection(movedBy: -1, in: three, from: three[1].id)
    #expect(up == three[0].id)
    #expect(TranscriptChatFilter.selection(movedBy: 1, in: [], from: "") == nil)
  }

  // MARK: The form

  @Test("The window covers whole days and refuses an inverted range")
  func window() {
    var form = TranscriptExportForm()
    #expect(form.window.after == nil)
    #expect(form.window.before == nil)
    #expect(form.problem == nil)

    let calendar = Calendar.current
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    form.limitsStart = true
    form.start = day
    form.limitsEnd = true
    form.end = day
    #expect(form.window.after == calendar.startOfDay(for: day))
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))?
      .addingTimeInterval(-1)
    #expect(form.window.before == endOfDay)
    #expect(form.problem == nil)

    form.end = day.addingTimeInterval(-3 * 86_400)
    #expect(form.problem == "The start date is after the end date.")
    form.limitsEnd = false
    form.meLabel = "  "
    #expect(form.problem == "Choose a label for your own messages.")
  }

  @Test("Files always travel as a ZIP, and the panel is told the type")
  func request() {
    var form = TranscriptExportForm()
    form.attachmentMode = .files
    form.format = .html
    let request = form.request(chatGUID: "g")
    #expect(request.archive)
    #expect(request.chatGUID == "g")
    #expect(form.contentType == .zip)
    form.attachmentMode = .metadata
    #expect(!form.request(chatGUID: "g").archive)
    #expect(form.contentType == .html)
    form.format = .json
    #expect(form.contentType == .json)
  }

  @Test("Every format and mode has a title and a help line")
  func titles() {
    for format in TranscriptFormat.allCases {
      #expect(!format.title.isEmpty)
      #expect(!format.help.isEmpty)
    }
    for mode in Transcript.AttachmentMode.allCases {
      #expect(!mode.title.isEmpty)
      #expect(!mode.help.isEmpty)
    }
  }
}
