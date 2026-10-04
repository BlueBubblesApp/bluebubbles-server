//  WebhookRetryChoiceTests
//  The webhook editor's retry controls, and what they save.
//
//  The switch and the count are separate on screen and one value in storage, which is where a
//  round trip can quietly go wrong: a count lost when the switch goes off, or a switch that
//  shows on over a stored policy that is off.

import BBEvents
import Testing

@testable import BlueBubblesApp

@Suite("Webhook retry choice")
struct WebhookRetryChoiceTests {

  @Test("A stored policy reads back as the same policy")
  func roundTrip() {
    let longest = WebhookRetryPolicy(maxRetries: 10, initialDelaySeconds: 900)
    for policy in [WebhookRetryPolicy.standard, .off, longest] {
      #expect(WebhookRetryChoice(policy: policy).policy == policy)
    }
  }

  @Test("Switching retries off saves zero, and switching back on keeps the count")
  func switchKeepsTheCount() {
    var choice = WebhookRetryChoice(
      policy: WebhookRetryPolicy(maxRetries: 7, initialDelaySeconds: 60))
    choice.isEnabled = false
    #expect(choice.policy.maxRetries == 0)
    #expect(!choice.policy.isEnabled)
    choice.isEnabled = true
    #expect(choice.policy.maxRetries == 7)
  }

  @Test("A webhook with retries off offers the standard count when switched on")
  func offStartsFromTheStandardCount() {
    var choice = WebhookRetryChoice(policy: .off)
    #expect(!choice.isEnabled)
    choice.isEnabled = true
    #expect(choice.retries == WebhookRetryPolicy.standard.maxRetries)
  }

  @Test("A stored wait that is not one of the standard ones is still offered")
  func customDelayIsOffered() {
    let choice = WebhookRetryChoice(
      policy: WebhookRetryPolicy(maxRetries: 3, initialDelaySeconds: 45))
    #expect(choice.delayOptions.contains(45))
    #expect(choice.delayOptions == choice.delayOptions.sorted())
    #expect(
      WebhookRetryChoice(policy: .standard).delayOptions == WebhookRetryChoice.standardDelays)
  }

  @Test("The schedule has one wait per retry, doubling")
  func scheduleDoubles() {
    let choice = WebhookRetryChoice(
      policy: WebhookRetryPolicy(maxRetries: 4, initialDelaySeconds: 10))
    #expect(choice.delays == [10, 20, 40, 80].map { Duration.seconds($0) })
    #expect(WebhookRetryChoice(policy: .off).delays.isEmpty)
  }

  @Test("The stepper cannot reach zero, which is the switch's job")
  func stepperStartsAtOne() {
    #expect(WebhookRetryChoice.retryRange.lowerBound == 1)
    #expect(WebhookRetryChoice.retryRange.upperBound == WebhookRetryPolicy.retryRange.upperBound)
  }
}
