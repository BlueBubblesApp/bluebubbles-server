//  ServiceGraphLifetimeTests
//  A wired composition is released when nothing holds it.
//
//  The app builds a FRESH composition on every Start, so anything the graph retains after a
//  Stop is leaked once per cycle, not once per process. What leaks is not one object: the
//  context owns the event bus, the socket server, the tool manager, the settings store and
//  the open `app.db` queue behind it, which is the handle the next start then contends with.
//
//  The cycle this pins was already understood and half fixed. `AppContext.registry` is `weak`
//  and carries a paragraph explaining that this is what breaks it. `AppContext.lifecycle` then
//  rebuilt the same cycle strongly through a different edge — context to lifecycle, lifecycle
//  to registry, registry to its host, which is the context — so the graph held itself up and
//  the comment saying otherwise was the reason nobody looked again.
//
//  A leak is invisible to every other kind of test: everything works, correctly, forever. The
//  only way to see it is to ask whether the object is gone, which is what this does.

import BBHTTPAPI
import BBServiceKit
import Testing

@testable import BlueBubblesServerCore

@Suite("Service graph lifetime")
struct ServiceGraphLifetimeTests {

  @Test("A context released after wiring is actually deallocated")
  func wiredContextIsReleased() async throws {
    weak var escaped: AppContext?
    do {
      let context = try await AppContextFixture.make()
      let registry = ServiceRegistry<AppContext>(host: context)
      await ServerComposition.registerServices(in: registry)
      await context.finishWiring(registry: registry, handlers: HandlerRegistry())
      escaped = context
      #expect(escaped != nil, "the fixture itself failed to build")
    }
    #expect(
      escaped == nil,
      """
      the wired composition retained itself. Every Stop/Start in the app leaks the context, \
      the event bus, the socket server, the settings store and its open app.db queue.
      """)
  }

  /// The unwired case, so a failure above is read as "wiring introduced it" rather than
  /// "the fixture leaks".
  @Test("An unwired context is deallocated, which is the control")
  func unwiredContextIsReleased() async throws {
    weak var escaped: AppContext?
    do {
      let context = try await AppContextFixture.make()
      escaped = context
      #expect(escaped != nil)
    }
    #expect(escaped == nil, "the fixture leaks on its own; the wiring test proves nothing")
  }
}
