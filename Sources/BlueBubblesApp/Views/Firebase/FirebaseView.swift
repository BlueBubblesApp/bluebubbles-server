//  FirebaseView
//  Push notification setup: the screen that makes `FirebaseProvisioner` reachable.
//
//  Push is OPTIONAL and this screen says so first, before it offers anything. A socket-only
//  or webhook-only install is a supported deployment that works perfectly, so the empty state
//  here is "not set up", not "misconfigured", and there is no warning colour anywhere on it.
//
//  Three ways in, matching `PushInterface`: create a project, import one, or arrive with
//  credentials migrated from an Electron install. See `docs/EVENTS.md`.
//
//  **Two files, not one.** Firebase setup needs a service account key (this server sends with
//  it) AND a `google-services.json` (clients fetch it from this server to know which project
//  to register with). They are separate downloads from separate corners of Google's console,
//  and having one without the other is a real, silent half-state. The Electron page showed
//  them as two labelled drop zones for exactly that reason; collapsing them into a single
//  file chooser hid which one was missing, so this screen puts them back.
//
//  All state lives on `FirebaseSetupModel`, not in `@State` here; see that file.
//
//  One file per card. This view composes the page, its drop target and its read; each card
//  under `Views/Firebase/` renders one concern from the same model, and the sheets and
//  dialogs a setup run parks on are `FirebaseSetupPrompts`, with their words decided by
//  `FirebaseSetupPrompt` off the view.

import AppKit
import BBBuiltIns
import BBInterfaces
import BBPushKit
import BBServiceKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

struct FirebaseView: View {

  @Bindable var model: AppModel

  private var setup: FirebaseSetupModel { model.firebaseSetup }
  private var status: PushStatus? { setup.status }

  /// The event sink that actually delivers what this page sets up. Through the catalog,
  /// never `BuiltInManifests.all` directly; see `IntegrationCatalog`.
  private var pushManifest: ServiceManifest? {
    IntegrationCatalog.manifest(BuiltInManifests.ID.push)
  }

  var body: some View {
    // The second stack in the app, and it lives HERE for the reason the Integrations one
    // does: a stack around the whole detail column intercepts the sidebar's own navigation.
    // A stack rather than a sheet, because the devices list needs a real Back button --
    // someone who goes in to remove a stale phone will want the Send Test button behind it.
    NavigationStack(path: $model.firebasePath) {
      page
        .navigationDestination(for: FirebaseDetail.self) { detail in
          switch detail {
          case .devices: FirebaseDevicesView(model: model)
          }
        }
    }
  }

  private var page: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "bell.badge"),
          purpose: "set up push notifications")
      } else {
        SettingsPage {
          // ABOVE the summary, because the summary cannot see this. It reports on
          // CREDENTIALS, so a server whose Firebase is complete but whose push sink is
          // switched off reads "Push notifications are set up" in green while nothing is
          // delivered to anybody. That is the lie `FeatureDisabledNotice` exists for, and
          // it has to be read before the green card, not after it.
          //
          // The rest of the page renders regardless, for the same reason the webhook rows
          // do: credentials are what someone came here to check or to repair, and hiding
          // them behind the switched-off state would mean turning delivery ON to fix the
          // thing that is stopping it working.
          if let manifest = pushManifest, !model.integrations.isEnabled(manifest) {
            FeatureDisabledNotice(
              manifest: manifest,
              model: model,
              placement: .card,
              consequence: "No notifications are reaching your devices, whatever is set "
                + "up below. The credentials and the registered devices are kept, and "
                + "delivery resumes as soon as this is turned back on."
            )
          }

          FirebaseSummaryCard(setup: setup)
          // Directly under the summary, NOT at the foot of the page. As caption
          // text below the transcript it is missed: the spinner stops and, as far
          // as the user can tell, nothing happened.
          FirebaseOutcomeBanner(outcome: setup.outcome)
          if status?.hasServiceAccount == true { FirebaseManageCard(model: model) }
          FirebaseCredentialsCard(model: model)
          if setup.isProvisioning || !setup.transcript.isEmpty {
            FirebaseTranscriptCard(setup: setup)
          }
          FirebaseNotices(setup: setup)
        }
        // The WHOLE page is a drop target, matching the Electron page. Someone
        // dragging two files from Downloads should not have to hit a 100pt rectangle
        // with each of them.
        .acceptsFileDrop { urls in
          setup.importFiles(urls, push: model.delivery.push)
        }
      }
    }
    // Keyed on the phase, NOT a bare `.task`.
    //
    // `refresh` returns immediately when `push` is nil, which it is until the server is up,
    // and a bare `.task` never runs again because the enclosing view's identity does not
    // change on a phase transition. So opening this page during startup — documented as
    // taking minutes on a large chat.db — left `status` nil, and the summary card renders
    // "Push notifications are not set up" with an empty subhead and no manage card, for a
    // server that is fully configured. This is the rule in the module's own guide: a page
    // that reads from the server reads again when the server starts.
    //
    // Whether push is switched on is NOT read here: `model.integrations` follows it from the
    // settings store for the life of the server.
    .task(id: model.phase.isRunning) {
      await setup.refresh(push: model.delivery.push)
    }
    // The project and billing panels and the two questions a guided run parks on.
    .modifier(FirebaseSetupPrompts(model: model))
  }
}
