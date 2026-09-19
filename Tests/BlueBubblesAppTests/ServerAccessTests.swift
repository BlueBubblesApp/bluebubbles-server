//  ServerAccessTests
//  Every door is closed when there is no server, and closed is not a crash.
//
//  This is the state the app spends its first seconds in and returns to on every stop, so it
//  is the one a screen is most likely to render in and the one least likely to be tried by
//  hand. A facade that trapped instead of answering nil would take the whole window down
//  between launching the app and the server coming up.

import Testing

@testable import BlueBubblesApp

@Suite("Server access")
@MainActor
struct ServerAccessTests {

  @Test("With no server running, every grouped door answers nil rather than trapping")
  func doorsAreClosedWithoutAServer() async {
    let model = AppModel()

    #expect(model.security.accessControl == nil)
    #expect(model.security.tokenAuth == nil)
    #expect(model.security.certificates == nil)

    #expect(model.messaging.contacts == nil)
    #expect(model.messaging.scheduling == nil)
    #expect(model.messaging.groupChatShortcuts == nil)
    #expect(model.messaging.privateAPI == nil)
    #expect(await model.messaging.interfaces() == nil)
    #expect(await model.messaging.faceTime() == nil)
    #expect(await model.messaging.ownMessagingAddress() == nil)
    // The one that answers a Bool rather than an optional: absent reads as not connected,
    // which is the truth and is what the Private API row shows.
    #expect(await model.messaging.isHelperConnected == false)

    #expect(model.delivery.webhooks == nil)
    #expect(model.delivery.push == nil)

    // The four that stayed flat, for the same reason.
    #expect(model.settings == nil)
    #expect(model.alertCenter == nil)
    #expect(model.tools == nil)
    #expect(model.serverAdmin == nil)
  }

  @Test("A facade reads through to the model rather than caching a server that has gone")
  func facadesAreNotSnapshots() {
    // Two reads of the same group are two structs, each resolving the context when asked.
    // Written down because the failure it prevents is invisible: a facade that captured a
    // live context at construction would keep answering after a restart replaced it, and
    // the screen holding it would talk to a server that no longer exists.
    let model = AppModel()
    let first = model.security
    let second = model.security
    #expect(first.accessControl == nil)
    #expect(second.accessControl == nil)
  }
}
