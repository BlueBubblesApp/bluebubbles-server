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
import BBHandlers
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
