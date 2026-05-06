// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import SanctuaryCore
import ServiceManagement

public enum DaemonInstallation {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed(running: Bool)
        case requiresApproval
    }

    static let daemonPlistName = "ai.hardener.sanctuary.daemon.plist"
    private static let approvalPaneURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    static var serviceFactory: @Sendable () -> any DaemonServiceManaging = {
        SMAppServiceDaemonAdapter(plistName: daemonPlistName)
    }
    static var daemonRunning: @Sendable () -> Bool = {
        SanctuaryDaemonDetector.statusText().hasPrefix("running")
    }

    public static func currentStatus() -> Status {
        status(for: serviceFactory().statusDescription, daemonRunning: daemonRunning())
    }

    public static func install() async throws {
        // SMAppService owns the privileged approval sheet text. We keep our
        // preflight LocalAuthentication reasons in verb-phrase form so macOS
        // can render them grammatically, but the service registration prompt
        // itself is not customizable from this API.
        try serviceFactory().register()
    }

    public static func uninstall() async throws {
        try serviceFactory().unregister()
    }

    public static func openSystemSettingsApprovalPane() throws {
        guard NSWorkspace.shared.open(approvalPaneURL) else {
            throw DaemonInstallationError.cannotOpenSystemSettings
        }
    }

    static func status(for serviceStatusDescription: String, daemonRunning: Bool) -> Status {
        let normalized = serviceStatusDescription.lowercased()
        if normalized.contains("requiresapproval") || normalized.contains("requires approval") {
            return .requiresApproval
        }
        if normalized.contains("notregistered") || normalized.contains("not registered") || normalized.contains("notfound") {
            return .notInstalled
        }
        if normalized.contains("enabled") || normalized.contains("registered") {
            return .installed(running: daemonRunning)
        }
        return .notInstalled
    }
}

enum DaemonInstallationError: Error, Equatable {
    case cannotOpenSystemSettings
}

protocol DaemonServiceManaging: Sendable {
    var statusDescription: String { get }
    func register() throws
    func unregister() throws
}

private struct SMAppServiceDaemonAdapter: DaemonServiceManaging {
    let plistName: String

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    var statusDescription: String {
        String(describing: service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
