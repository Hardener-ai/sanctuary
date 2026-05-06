// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import Security

public struct CodeSigningInfo: Equatable, Sendable {
    public let signingIdentifier: String?
    public let teamIdentifier: String?

    public init(signingIdentifier: String?, teamIdentifier: String?) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public protocol CodeSigningInspecting: Sendable {
    func inspect(pid: pid_t) -> CodeSigningInfo?
}

public struct CodeSigningInspector: CodeSigningInspecting {
    public init() {}

    public func inspect(pid: pid_t) -> CodeSigningInfo? {
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        var guest: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest)
        guard guestStatus == errSecSuccess, let guest else {
            return nil
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(guest, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information)
        if infoStatus == errSecCSUnsigned {
            return CodeSigningInfo(signingIdentifier: nil, teamIdentifier: nil)
        }
        guard infoStatus == errSecSuccess, let information else {
            return nil
        }

        let dictionary = information as NSDictionary
        return CodeSigningInfo(
            signingIdentifier: dictionary[kSecCodeInfoIdentifier] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier] as? String
        )
    }
}
