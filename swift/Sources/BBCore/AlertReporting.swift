//  AlertReporting
//  The narrowest way a module can tell the user something without knowing about alerts.
//
//  `BBDiagnostics` owns `AlertCenter` and the full `UserAlert` shape. Modules below it (the
//  Private API runtime, push) still have things a person must hear about, and this is the
//  one protocol they report through, rather than one per module with its own bridge in the
//  composition root.
//
//  A title and a sentence, nothing more: the module reporting knows what happened, and the
//  centre decides severity, source and dedupe on its behalf; see `AlertCenterReporter`.

public protocol AlertReporting: Sendable {
  func raise(title: String, detail: String) async
}
