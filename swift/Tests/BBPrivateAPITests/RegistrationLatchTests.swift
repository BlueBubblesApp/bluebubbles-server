//  RegistrationLatchTests
//  Waiting for a helper to register must END, and must answer from the count.
//
//  `startDeadline` exists so a Private API that cannot come up does not hang the server.
//  That guarantee was once defeated from inside: the wait was a task group whose waiter
//  parked on a `withCheckedContinuation`, and `cancelAll()` does not resume a continuation —
//  so when the timeout branch returned, the group went on awaiting a child that would never
//  finish. The deadline fired and nothing happened.
//
//  The second bug was quieter. The waiter was handed to the actor through a `Task`, so a
//  registration arriving during that hop resumed a list the waiter was not yet on. Injection
//  then reported that the helper had never registered when it had.
//
//  These drive the latch directly, which is the point of it being its own type: the only
//  other way into this logic is quitting and relaunching Messages.

import Foundation
import Testing

@testable import BBPrivateAPI

@Suite("Registration latch")
struct RegistrationLatchTests {

  @Test("A wait that is never satisfied ends at its timeout")
  func timesOutRatherThanHanging() async throws {
    // The whole test is that this RETURNS. The old shape parked forever, so its failure
    // mode was the suite hanging rather than an assertion failing.
    let latch = RegistrationLatch()
    let started = ContinuousClock.now

    let registered = await latch.wait(
      for: "com.apple.MobileSMS", after: 0, timeout: .milliseconds(200)
    )

    #expect(!registered)
    #expect(ContinuousClock.now - started < .seconds(5))
  }

  @Test("A registration that arrives while waiting resolves the wait")
  func registrationWakesTheWaiter() async throws {
    let latch = RegistrationLatch()

    async let waiting = latch.wait(for: "com.apple.FaceTime", after: 0, timeout: .seconds(10))
    try await Task.sleep(for: .milliseconds(50))
    await latch.observe("com.apple.FaceTime")

    #expect(await waiting)
  }

  @Test("A registration for another process does not satisfy this wait")
  func otherProcessDoesNotCount() async throws {
    // Short-circuiting on "something registered" is wrong once there are two helpers:
    // injecting FaceTime would report success because Messages was already up.
    let latch = RegistrationLatch()

    async let waiting = latch.wait(for: "com.apple.FaceTime", after: 0, timeout: .milliseconds(300))
    try await Task.sleep(for: .milliseconds(50))
    await latch.observe("com.apple.MobileSMS")

    #expect(!(await waiting))
  }

  @Test("A registration already newer than the baseline returns without waiting")
  func alreadyRegisteredReturnsImmediately() async throws {
    let latch = RegistrationLatch()
    await latch.observe("com.apple.MobileSMS")

    let started = ContinuousClock.now
    let registered = await latch.wait(
      for: "com.apple.MobileSMS", after: 0, timeout: .seconds(30)
    )

    #expect(registered)
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  @Test("The registration that already existed does not satisfy a newer baseline")
  func baselineExcludesTheExistingRegistration() async throws {
    // The measured bug: re-injecting an already-connected app short-circuited on the
    // existing registration and reported success having done nothing.
    let latch = RegistrationLatch()
    await latch.observe("com.apple.MobileSMS")
    let baseline = await latch.count(of: "com.apple.MobileSMS")

    let registered = await latch.wait(
      for: "com.apple.MobileSMS", after: baseline, timeout: .milliseconds(200)
    )

    #expect(!registered)
  }

  @Test("Shutdown releases a waiter rather than stranding it")
  func releaseAllUnparksWaiters() async throws {
    let latch = RegistrationLatch()

    async let waiting = latch.wait(for: "com.apple.FaceTime", after: 0, timeout: .seconds(30))
    try await Task.sleep(for: .milliseconds(50))
    await latch.releaseAll()

    // Released, and honest about it: nothing registered, so the answer is still no.
    #expect(!(await waiting))
  }
}
