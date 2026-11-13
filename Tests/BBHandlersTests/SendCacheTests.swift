//  SendCacheTests
//  One `tempGuid`, one send.
//
//  The window this closes is the hydration wait: a send holds its response until the row
//  appears in `chat.db`, up to 60 seconds, so a client with a 30-second timeout gives up and
//  retries while the first send is still in flight. The retry is the client behaving
//  correctly. Sending the message twice, into a real conversation, is what this server did
//  about it.
//
//  What is asserted here is the claim's shape, because that is what decides the behaviour:
//  what is refused, what is not, and — the half that matters more — what happens to a claim
//  nobody released.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBHandlers

@Suite("Send cache")
struct SendCacheTests {

  @Test("A second send under the same temp GUID is refused while the first is in flight")
  func duplicateIsRefused() async {
    let cache = SendCache()
    #expect(await cache.claim("A5E1-1") == true)
    #expect(await cache.claim("A5E1-1") == false)
  }

  /// The claim is for the send, not for the id: once the first finishes, the same client may
  /// send again under the same `tempGuid`. That is what makes this an in-flight guard rather
  /// than an idempotency key, and it is deliberate — the reference has no memory of a
  /// completed send either.
  @Test("Once the send finishes the temp GUID sends again")
  func releaseAllowsTheNextSend() async {
    let cache = SendCache()
    #expect(await cache.claim("A5E1-2") == true)
    await cache.release("A5E1-2")
    #expect(await cache.claim("A5E1-2") == true)
  }

  /// Failure releases too. A send that failed is one the client SHOULD retry, and holding
  /// the claim would turn one failure into two minutes of refusals.
  @Test("A failed send does not hold its claim")
  func failureReleases() async {
    let cache = SendCache()
    _ = await cache.claim("A5E1-3")
    // The `defer` in the handler runs on the throwing path as well as the returning one.
    await cache.release("A5E1-3")
    #expect(await cache.claim("A5E1-3") == true)
  }

  @Test("Different temp GUIDs do not block each other")
  func distinctGUIDs() async {
    let cache = SendCache()
    #expect(await cache.claim("A5E1-4") == true)
    #expect(await cache.claim("A5E1-5") == true)
  }

  /// A client that sends no `tempGuid` cannot be deduplicated, and must not be refused for
  /// it: most sends carry none, and a shared "" claim would let the first anonymous send
  /// block every other one.
  @Test("A send with no temp GUID is never refused")
  func anonymousSendsAreNeverRefused() async {
    let cache = SendCache()
    #expect(await cache.claim(nil) == true)
    #expect(await cache.claim(nil) == true)
    #expect(await cache.claim("") == true)
    #expect(await cache.claim("") == true)
    // And releasing one does not disturb the cache.
    await cache.release(nil)
    await cache.release("")
    #expect(await cache.count == 0)
  }

  /// **The property that keeps a bug here from being permanent.** A claim that leaked — a
  /// crash between claiming and releasing, a path that throws somewhere unforeseen — expires
  /// on its own. Without this the client is locked out of its own `tempGuid` until the
  /// process restarts, which is worse than the duplicate send this exists to prevent.
  @Test("A claim nobody released expires on its own")
  func claimsExpire() async throws {
    let cache = SendCache(ttl: .milliseconds(120))
    #expect(await cache.claim("A5E1-6") == true)
    #expect(await cache.claim("A5E1-6") == false)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await cache.claim("A5E1-6") == true, "a leaked claim outlived its TTL")
  }

  /// The key is client-supplied, so a client looping on fresh ids must not be able to grow
  /// this without limit. At the cap the oldest claim is dropped, which at worst allows the
  /// duplicate this exists to prevent — the same outcome as having no cache, and never a
  /// refusal of a legitimate send.
  @Test("A flood of temp GUIDs is bounded, and drops the oldest rather than refusing")
  func boundedUnderFlood() async {
    let cache = SendCache(capacity: 8)
    for index in 0..<200 {
      #expect(await cache.claim("flood-\(index)") == true)
    }
    #expect(await cache.count <= 8)
    // The newest claims are the ones still held.
    #expect(await cache.claim("flood-199") == false)
  }

  /// The sentence a duplicate gets is the reference's, from the socket path that is the only
  /// place it ever checked its own cache.
  @Test("The refusal names the temp GUID, in the reference's words")
  func refusalWording() {
    let refusal = WriteHandlers.alreadySending("A5E1-7")
    #expect(refusal.errorMessage == "Message is already queued to be sent (Temp GUID: A5E1-7)!")
  }
}
