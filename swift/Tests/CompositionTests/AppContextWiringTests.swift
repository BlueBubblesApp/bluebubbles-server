//  AppContextWiringTests
//  The late-binding points, asserted.
//
//  `AppContext` cannot take everything through its initialiser: the HTTP handlers close over
//  the context, so building them first would require the context first. That knot is real.
//  What was not real was needing SIX separate places to untie it, none of them checked by
//  anything — and two of those six turned out never to be called at all:
//
//    - `contactsIngestor` was an optional, defaulted parameter on the Private API
//      publication. Nothing passed it, so `ContactInterface.refresh` ran with nil for the
//      life of every process and answered "contact access has not been granted to this
//      server" on servers where it plainly had been.
//    - `updateInstaller` had a public setter with no callers and no conforming type, so
//      `server.installUpdate` always refused — while blaming headless operation, which it
//      could not know.
//
//  Both were invisible to the compiler and unreachable by a test, because there was no way to
//  build an `AppContext`. `AppContextFixture` is that way, and these are the assertions it
//  makes possible.

import BBContacts
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBServiceKit
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("App context wiring")
struct AppContextWiringTests {

  // MARK: - Construction

  /// A context that skipped `finishWiring` looks healthy and fails obscurely later: no
  /// service resolves and no route has a controller.
  @Test("A freshly built context reports itself unwired")
  func startsUnwired() async throws {
    let context = try await AppContextFixture.make()
    #expect(await context.isWired == false)
  }

  /// One call, not two. The registry and the handlers were separate `attach` calls made
  /// back to back, which is two chances to make only one.
  @Test("finishWiring closes the cycle in a single call")
  func wiringIsOneCall() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)

    var handlers = HandlerRegistry()
    handlers.register(.generalPing) { _ in .data(.string("pong")) }

    await context.finishWiring(registry: registry, handlers: handlers)

    #expect(await context.isWired)
    #expect(await context.httpHandlers.handler(for: .generalPing) != nil)
  }

  // MARK: - The Private API pair

  /// The connection and the process control are published together and withdrawn together.
  ///
  /// As four separate calls they drift: put the two clears either side of `runtime.stop()`
  /// and for the length of that await the runtime is already gone while the client is still
  /// published, so `isHelperConnected` answers for a helper being torn down.
  @Test("Publishing and withdrawing the Private API moves both halves together")
  func privateAPIPairIsAtomic() async throws {
    let context = try await AppContextFixture.make()
    #expect(await context.privateAPIRuntime == nil)
    #expect(await context.isHelperConnected == false)

    await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)
    // The client is published even with no runtime — that is the injection-managed case,
    // where the helper connects to a Messages the server did not launch.
    #expect(await context.privateAPIClient() != nil)

    await context.withdrawPrivateAPI()
    #expect(await context.privateAPIClient() == nil)
    #expect(await context.privateAPIRuntime == nil)
    #expect(await context.isHelperConnected == false)
  }

  // MARK: - The cache the published state feeds

  /// REGRESSION GUARD, for a bug that has not happened. `interfaces()` caches, and what it
  /// caches holds whatever the Private API was when it was built. An interface built before
  /// the helper connected holds nil and would go on reporting the Private API as unavailable
  /// for the life of the process — a working helper that looks broken.
  ///
  /// The invalidation used to be a line written by hand at each site that changed the
  /// published state. It is now a `didSet` on the one value those sites write, so a new field
  /// cannot forget it. This asserts the behaviour that arrangement exists to guarantee.
  @Test("Interfaces built before the Private API arrives are rebuilt after it does")
  func publishingRebuildsTheInterfaces() async throws {
    let context = try await AppContextFixture.make(withMessageAccess: true)

    let before = try #require(await context.interfaces())
    #expect(await before.message.availableBackend() == .appleScript)

    await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)

    let after = try #require(await context.interfaces())
    #expect(await after.message.availableBackend() == .privateAPI)
  }

  /// And back, so a helper going away is equally visible. Withdrawing without invalidating
  /// would leave every interface holding a client whose transport has stopped.
  @Test("Withdrawing the Private API rebuilds them again")
  func withdrawingRebuildsTheInterfaces() async throws {
    let context = try await AppContextFixture.make(withMessageAccess: true)
    await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)
    _ = await context.interfaces()

    await context.withdrawPrivateAPI()

    let after = try #require(await context.interfaces())
    #expect(await after.message.availableBackend() == .appleScript)
  }

  /// The same property for the other published slot, and the one whose absence actually
  /// shipped: `contact/refresh` refused on every server because the ingestor was never
  /// published. Publishing it after the interfaces exist has to reach them.
  @Test("Publishing the contacts ingestor reaches an already-built interface")
  func publishingIngestorRebuildsTheInterfaces() async throws {
    let context = try await AppContextFixture.make(withMessageAccess: true)

    let before = try #require(await context.interfaces())
    await #expect(throws: InterfaceError.self) { _ = try await before.contact.refresh() }

    await context.publish(contactsIngestor: ContactsIngestor(index: context.contacts))

    let after = try #require(await context.interfaces())
    // Reaches the ingestor now. It may still fail for its own reason — a test process has no
    // Contacts access — but no longer with the nil path's "not granted to this server".
    do {
      _ = try await after.contact.refresh()
    } catch let error as InterfaceError {
      #expect(error != .unavailable("contact access has not been granted to this server"))
    } catch {
      // Any other error means it got past the nil check, which is what is being asserted.
    }
  }

  // MARK: - The two that were never called

  /// REGRESSION. `contact/refresh` — the API route and the app's "Refresh from Address
  /// Book" button — refused on every server, because the ingestor was never published.
  /// `ContactInterface` throws `.unavailable` when it holds nil, which is what every user
  /// saw regardless of their actual Contacts permission.
  @Test("The contacts ingestor is nil until something publishes it")
  func contactsIngestorMustBePublished() async throws {
    let context = try await AppContextFixture.make()
    #expect(await context.contactsIngestor == nil)

    await context.publish(contactsIngestor: ContactsIngestor(index: context.contacts))

    #expect(await context.contactsIngestor != nil)
  }

  /// `UpdateInstalling` has no conforming type anywhere, so this stays nil in every
  /// configuration. Asserted so the day someone implements one, the test says what changed.
  @Test("No update installer is wired, in any configuration")
  func noUpdateInstallerIsWired() async throws {
    let context = try await AppContextFixture.make()
    #expect(await context.updateInstaller == nil)
  }

}
