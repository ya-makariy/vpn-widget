import Foundation
import AppKit

/// Starts and stops profiles the way their clients allow. The system call is
/// tried first; if it is refused, `scutil` and finally the client's own app.
public struct SystemProviderHooks: ProviderHooks {
    public init() {}

    public func start(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws {
        do {
            try await controller.start(profile.id)
        } catch {
            if let name, try await scutil("start", name) { return }
            if await openClient(profile.providerKind) {
                throw ActionError("could not start it here; finish in \(profile.providerKind.displayName)")
            }
            throw error
        }
    }

    public func stop(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws {
        do {
            try await controller.stop(profile.id)
        } catch {
            if let name, try await scutil("stop", name) { return }
            throw error
        }
    }

    private func scutil(_ verb: String, _ name: String) async throws -> Bool {
        let (status, _) = try await runProcess("/usr/sbin/scutil", ["--nc", verb, name])
        return status == 0
    }

    @MainActor
    private func openClient(_ kind: ProviderKind) -> Bool {
        for bundleID in kind.clientBundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return false
    }
}
