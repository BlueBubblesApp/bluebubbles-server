//  ScreenModelTests
//  The load half of an administration screen, tested without a server.
//
//  This is what the view-model tier is FOR. Left in a private method inside a `View` struct
//  and rewritten per screen, none of these behaviours can be exercised at all — which is how
//  a screen ships with an error view nothing ever assigns to, or reads a list with
//  `(try? …) ?? []` and turns "the server refused" into "there are none".
//
//  The cases below are the ones that are easy to get wrong, written as assertions:
//
//    - a read that throws must produce a message, not an empty collection
//    - a FAILED REFRESH must keep the value already on screen
//    - an action failure must not replace the list with an error state
//    - "the server is not running" must not be reported as an error
//
//  See `Sources/BlueBubblesApp/ScreenModel.swift`.

import BBCore
import Testing

@testable import BlueBubblesApp

@Suite("Screen model")
@MainActor
struct ScreenModelTests {

  /// A failure with a sentence of its own, which `DiagnosticText` must prefer over
  /// `String(describing:)`.
  private struct Refused: BBError {
    var code = "test.refused"
    var domain = "Test"
    var title = "Refused"
    var body = "The server refused to answer."
  }

  private struct Unlabelled: Error {}

  /// A mutable flag the read closure can consult.
  ///
  /// A captured `var` mutated afterwards is a concurrency warning — the closure is
  /// `@Sendable`, so the value it captured and the one the test goes on changing are not
  /// the same storage. A reference is.
  private final class Flag: @unchecked Sendable {
    var isSet: Bool
    init(_ isSet: Bool) { self.isSet = isSet }
  }

  /// The same trick for the value the read returns.
  private final class Store: @unchecked Sendable {
    var values: [String]
    init(_ values: [String]) { self.values = values }
  }

  // MARK: - Reading

  @Test("A successful read loads its value")
  func readLoads() async {
    let model = ScreenModel<[String]> { ["a", "b"] }
    #expect(model.state.value == nil)

    await model.reload()

    #expect(model.state.value == ["a", "b"])
    #expect(model.problem == nil)
    #expect(!model.state.isLoading)
  }

  /// The bug this whole type exists to prevent. `(try? await …) ?? []` made this case
  /// indistinguishable from an empty result.
  @Test("A read that throws reports a message rather than an empty result")
  func readFailureIsNotEmptiness() async {
    let model = ScreenModel<[String]> { throw Refused() }

    await model.reload()

    #expect(model.state.value == nil, "a failed read must not present as a loaded empty list")
    #expect(model.problem == "The server refused to answer.")
  }

  /// `BBError.body` is written to be read by someone who is not a developer.
  /// `String(describing:)` on an error enum renders the case, escaped quotes and all.
  @Test("A failure message prefers the error's own sentence")
  func failureMessagePrefersBBErrorBody() async {
    let described = ScreenModel<Int> { throw Unlabelled() }
    await described.reload()
    #expect(described.problem != nil)

    let labelled = ScreenModel<Int> { throw Refused() }
    await labelled.reload()
    #expect(labelled.problem == "The server refused to answer.")
  }

  /// Nil is "not available yet", not "failed" — the server has not started. Reporting it
  /// as an error would put a red message on every one of these pages at app launch.
  @Test("An unavailable capability stays idle rather than failing")
  func unavailableIsNotAFailure() async {
    let model = ScreenModel<[String]> { nil }

    await model.reload()

    #expect(model.problem == nil)
    #expect(model.state.value == nil)
    if case .idle = model.state {
    } else {
      Issue.record("expected idle, got \(model.state)")
    }
  }

  /// A refresh that fails must not blank the page underneath the person reading it.
  @Test("A failed refresh keeps the value already loaded")
  func failedRefreshKeepsValue() async {
    let shouldFail = Flag(false)
    let model = ScreenModel<[String]> {
      if shouldFail.isSet { throw Refused() }
      return ["kept"]
    }

    await model.reload()
    #expect(model.state.value == ["kept"])

    shouldFail.isSet = true
    await model.reload()

    #expect(model.state.value == ["kept"], "the loaded value must survive a failed refresh")
    #expect(model.problem == "The server refused to answer.")
  }

  // MARK: - Actions

  @Test("An action re-reads on success")
  func actionRefreshes() async {
    let stored = Store(["one"])
    let model = ScreenModel<[String]> { stored.values }
    await model.reload()

    await model.perform { stored.values.append("two") }

    #expect(model.state.value == ["one", "two"])
    #expect(model.problem == nil)
  }

  /// An action failing is a message beside a list that is still perfectly valid — not a
  /// reason to replace the list with an error page.
  @Test("A failed action reports without discarding the list")
  func actionFailureKeepsList() async {
    let model = ScreenModel<[String]> { ["still here"] }
    await model.reload()

    await model.perform { throw Refused() }

    #expect(model.state.value == ["still here"])
    #expect(model.problem == "The server refused to answer.")
  }

  /// The action may have partly applied before it threw, so the page must not show state
  /// from before it ran.
  @Test("A failed action still re-reads")
  func failedActionStillRefreshes() async {
    let stored = Store(["before"])
    let model = ScreenModel<[String]> { stored.values }
    await model.reload()

    await model.perform {
      stored.values = ["after"]
      throw Refused()
    }

    #expect(model.state.value == ["after"])
    #expect(model.problem != nil)
  }

  /// For the handful of actions with one overwhelmingly likely cause the error does not
  /// name — a contacts re-index failing on a missing permission.
  @Test("A supplied failure message replaces the error's own")
  func failureMessageOverride() async {
    let model = ScreenModel<[String]> { [] }
    await model.reload()

    await model.perform(failureMessage: "check Contacts permission") { throw Refused() }

    #expect(model.problem == "check Contacts permission")
  }

  @Test("A succeeding action clears the previous failure")
  func successClearsPreviousFailure() async {
    let model = ScreenModel<[String]> { [] }
    await model.reload()

    await model.perform { throw Refused() }
    #expect(model.problem != nil)

    await model.perform {}
    #expect(model.problem == nil)
  }

  // MARK: - What the screens read

  /// `problem` is what an empty-state branch has to consult before deciding it is empty:
  /// a failed read has no value, so `value ?? []` is empty, and a page keyed off the count
  /// alone renders "nothing here yet" over an error.
  @Test("An action failure takes precedence over a read failure")
  func actionFailureWins() async {
    let shouldFail = Flag(true)
    let model = ScreenModel<[String]> {
      if shouldFail.isSet { throw Refused() }
      return []
    }
    await model.reload()
    #expect(model.problem == "The server refused to answer.")

    shouldFail.isSet = false
    await model.perform(failureMessage: "the action's own message") { throw Unlabelled() }

    #expect(model.problem == "the action's own message")
  }
}
