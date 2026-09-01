//  AppContextCapabilities
//  Which capabilities `AppContext` satisfies.
//
//  The protocols live in BBHandlers, because they describe what a HANDLER may reach. The
//  conformances live here, because `AppContext` is the composition root's type — and this file
//  is the whole of what connects the two. It is deliberately nothing but a list: every member
//  already exists on the context, so a conformance that stops compiling means a capability
//  gained a requirement the container does not meet, which is exactly the failure worth
//  seeing.

import BBHandlers
import BBInterfaces

// MARK: - Conformance

// Every member below already existed on `AppContext`; these declare which of them are
// contracts other code is allowed to depend on. Empty conformances, because the point is
// the constraint rather than any new behaviour.
extension AppContext: InterfaceProviding {}
extension AppContext: SettingsProviding {}
extension AppContext: AlertProviding {}
extension AppContext: LoggerProviding {}
extension AppContext: ContactIndexProviding {}
extension AppContext: ServerInterfaceProviding {}
extension AppContext: ScheduleProviding {}
extension AppContext: DeviceRegistering {}
extension AppContext: PrivateAPIProviding {}
extension AppContext: PrivateAPIRuntimeProviding {}
extension AppContext: FaceTimeProviding {}
extension AppContext: FindMyProviding {}
extension AppContext: AttachmentConverting {}
extension AppContext: ToolProviding {}
extension AppContext: PermissionsProviding {}
extension AppContext: PushSetupProviding {}
extension AppContext: WebhookAdministering {}
extension AppContext: AccessControlProviding {}
extension AppContext: TokenAuthProviding {}
extension AppContext: UpdateInstallerProviding {}
extension AppContext: ServerControlling {}
extension AppContext: ServerStatusProviding {}
