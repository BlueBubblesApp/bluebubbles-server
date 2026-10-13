//  ListPagePolicyTests
//  Which state a list page draws, in the order the rules outrank each other.
//
//  Each case here was a bug on one of the five pages before `ListPage` decided it once:
//  an empty state over a read in flight, an empty state over a read that failed, and stale
//  rows on a stopped server.

import Testing

@testable import BlueBubblesApp

@Suite("List page policy")
struct ListPagePolicyTests {

  @Test("A stopped server outranks everything, including rows still in hand")
  func stopped() {
    #expect(
      ListPagePolicy.state(isRunning: false, isLoading: false, isEmpty: false, problem: nil)
        == .stopped)
    #expect(
      ListPagePolicy.state(
        isRunning: false, isDisabled: true, isLoading: true, isEmpty: true, problem: "x")
        == .stopped)
  }

  @Test("A switched-off feature outranks the read")
  func disabled() {
    #expect(
      ListPagePolicy.state(
        isRunning: true, isDisabled: true, isLoading: false, isEmpty: false, problem: nil)
        == .disabled)
    #expect(
      ListPagePolicy.state(
        isRunning: true, isDisabled: true, isLoading: false, isEmpty: true, problem: "refused")
        == .disabled)
  }

  @Test("Nothing in hand while reading is loading, never empty")
  func loading() {
    #expect(
      ListPagePolicy.state(isRunning: true, isLoading: true, isEmpty: true, problem: nil)
        == .running(.loading))
  }

  @Test("Rows in hand are shown through a re-read")
  func refreshing() {
    #expect(
      ListPagePolicy.content(isLoading: true, isEmpty: false, problem: nil) == .listing)
  }

  @Test("The empty state is shown only for a read that succeeded")
  func empty() {
    #expect(ListPagePolicy.content(isLoading: false, isEmpty: true, problem: nil) == .empty)
    // A read that failed has no rows either; the rows carry the error line instead of an
    // invitation that would be a lie.
    #expect(
      ListPagePolicy.content(isLoading: false, isEmpty: true, problem: "refused") == .listing)
  }

  @Test("Rows are listed, with or without a problem beside them")
  func listing() {
    #expect(ListPagePolicy.content(isLoading: false, isEmpty: false, problem: nil) == .listing)
    #expect(
      ListPagePolicy.content(isLoading: false, isEmpty: false, problem: "stale") == .listing)
  }
}
