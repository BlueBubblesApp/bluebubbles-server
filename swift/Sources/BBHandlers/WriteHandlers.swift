//  WriteHandlers
//  Controllers for everything that changes state in Messages.
//
//  Most of these need the Private API, and the route table already declares that with
//  `requires: .privateAPI` so the middleware rejects them before a handler runs. The
//  exceptions are the send routes: AppleScript is a supported fallback, not a degraded mode,
//  and `MessageInterface` picks between the two. See `.claude/docs/imessage.md`.

import BBDiagnostics
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

public enum WriteHandlers {

  /// Every route that changes state in Messages, one slice per file, divided the way the
  /// interfaces layer is, so a handler sits beside the interface it calls.
  public static func register(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & InterfaceProviding & UploadStoring
  ) {
    registerSending(into: &registry, context: context)
    registerMultipart(into: &registry, context: context)
    registerMutation(into: &registry, context: context)
    registerScheduling(into: &registry, context: context)
    registerAppMessages(into: &registry, context: context)
    registerChatAdministration(into: &registry, context: context)
    registerChatControls(into: &registry, context: context)
  }
}
