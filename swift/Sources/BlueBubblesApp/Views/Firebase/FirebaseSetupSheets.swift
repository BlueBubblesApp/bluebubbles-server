//  FirebaseSetupSheets
//  The two panels a guided setup run parks on: which project, and Google's billing step.
//
//  Presented by `FirebaseView` from state held on `FirebaseSetupModel`, so navigating away
//  and back re-presents whichever panel the run is still waiting on.

import AppKit
import BBInterfaces
import BBPushKit
import BlueBubblesServerCore
import SwiftUI
import UniformTypeIdentifiers

/// Choosing which Firebase project this server should use.
///
/// Offered on every guided run, including when the account has no projects yet; the list is
/// then empty and "Create a new project" is the only row, which reads correctly rather than
/// as a dead end.
///
/// Adoption is the preferred outcome and the ordering says so. FCM registration tokens are
/// scoped to a project, so creating a new one silently invalidates every client already
/// registered against the old one; reusing a project is the difference between "reconnect
/// your phone" and nothing at all.
struct ProjectPicker: View {

  let projects: [FirebaseProjectSummary]
  let onChoose: (String?) -> Void
  let onCancel: () -> Void

  @State private var selection: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Choose a Firebase project").font(.headline)
        Text(
          """
          Use a project you already have, or create a new one. Reusing the project \
          your clients are already registered with means they keep working without \
          reconnecting.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)

      Divider()

      List(selection: $selection) {
        Section {
          row(
            id: nil,
            title: "Create a new project",
            subtitle: "A fresh project, set up from scratch. Clients registered "
              + "with another project will need to reconnect.",
            icon: "plus.circle"
          )
        }
        if !projects.isEmpty {
          Section("Existing projects") {
            ForEach(projects) { project in
              row(
                id: project.projectId,
                title: project.displayName,
                subtitle: project.isActive
                  ? project.projectId
                  : "\(project.projectId): being deleted, cannot be used",
                icon: "cube",
                enabled: project.isActive
              )
            }
          }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 220)

      Divider()

      HStack {
        Button("Cancel", role: .cancel) { onCancel() }
        Spacer()
        Button("Continue") { onChoose(selection) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(minWidth: 440, idealWidth: 520, minHeight: 380, idealHeight: 460)
  }

  private func row(
    id: String?,
    title: String,
    subtitle: String,
    icon: String,
    enabled: Bool = true
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(enabled ? Color.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body)
        Text(subtitle)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .tag(id)
    .disabled(!enabled)
  }
}

/// Google requires a billing account on a project before it will create a Firestore database.
///
/// Presented as a step to complete, not as a failure, because that is what it is: by the time
/// this appears the project, its APIs, its Admin SDK key and its Android app all exist; only
/// the database is missing. Continuing resumes into that same project.
///
/// A sheet rather than a confirmation dialog specifically because it has to stay open while
/// the user goes to Google. Any button in a dialog dismisses it, so "Open Billing Settings"
/// would take the "Continue" button away with it.
struct BillingSheet: View {

  let projectId: String
  let consoleURL: URL?
  let onContinue: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Label("Firebase needs a billing account", systemImage: "creditcard")
          .font(.headline)

        Text(
          """
          Google will not create the Firestore database this server uses until \
          project \(projectId) has a billing account attached. Everything else is \
          already set up.
          """
        )
        .fixedSize(horizontal: false, vertical: true)

        // The reassurance is the point. Being asked for a card by Google, to run
        // something advertised as free, reads as a trap, and the honest answer is
        // that the usage genuinely is free, so say so plainly rather than leaving
        // people to guess.
        Text(
          """
          Cloud Messaging is free, and this server writes a single small document \
          to the database. Adding billing should not result in a charge, and you \
          can downgrade the plan again afterwards.
          """
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
          Text("What to do").font(.subheadline).bold()
          step(1, "Open the billing settings for this project.")
          step(2, "Link a billing account, creating one if you do not have it.")
          step(3, "Come back here and continue; setup picks up where it stopped.")
        }
        .padding(.top, 2)

        if let consoleURL {
          Link(destination: consoleURL) {
            Label("Open Billing Settings", systemImage: "arrow.up.forward.square")
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(20)

      Divider()

      HStack {
        Button("Cancel Setup", role: .cancel) { onCancel() }
        Spacer()
        Button("Continue, I've Configured Billing") { onContinue() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(minWidth: 460, idealWidth: 540)
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      Text(text).font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }
}
