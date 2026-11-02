import AppKit
import Foundation

/// Starts and stops profiles the way their clients allow.
///
/// WireGuard and AmneziaWG tunnels start through the system like any VPN.
/// FortiClient's extension needs the sign-in token that only FortiClient's own
/// window obtains through SAML, so the system start fails at once; the widget
/// brings FortiClient up instead and the user clicks Connect there. AnyConnect
/// on Apple silicon is the iPhone app, which the system start leaves waiting
/// for a password nobody is asked for; its `anyconnect://` URL opens the app
/// on the connection and asks.
public struct SystemProviderHooks: ProviderHooks {
    public init() {}

    public func start(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws -> StartOutcome {
        switch profile.providerKind {
        case .forticlient:
            guard await Self.openClient(.forticlient) else {
                throw ActionError("FortiClient is not installed")
            }
            return .handedToClient(hint: FortiClientConfig.connectHint())
        case .anyconnect:
            if let name, let url = Self.anyConnectURL(connect: name), await Self.open(url) {
                return .handedToClient(hint: "Enter your credentials in AnyConnect")
            }
            try await controller.start(profile.id)
            return .started
        case .amneziawg, .wireguard, .other:
            do {
                try await controller.start(profile.id)
                return .started
            } catch {
                if let name, try await scutil("start", name) { return .started }
                if await Self.openClient(profile.providerKind) {
                    return .handedToClient(hint: "Connect in \(profile.providerKind.displayName)")
                }
                throw error
            }
        }
    }

    public func stop(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws {
        do {
            try await controller.stop(profile.id)
        } catch {
            if let name, try await scutil("stop", name) { return }
            if profile.providerKind == .anyconnect, let url = URL(string: "anyconnect://disconnect/"), await Self.open(url) { return }
            throw error
        }
    }

    static func anyConnectURL(connect name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "anyconnect"
        components.host = "connect"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    private func scutil(_ verb: String, _ name: String) async throws -> Bool {
        let (status, _) = try await runProcess("/usr/sbin/scutil", ["--nc", verb, name])
        return status == 0
    }

    @MainActor
    private static func openClient(_ kind: ProviderKind) async -> Bool {
        for bundleID in kind.clientBundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    @MainActor
    private static func open(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
