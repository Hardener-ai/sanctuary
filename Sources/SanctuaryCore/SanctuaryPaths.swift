// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public enum SanctuaryPaths {
    public static let productionDirectory = "/var/db/sanctuary"
    public static let policyDatabaseFileName = "policy.sqlite"
    public static let auditLogFileName = "audit.log"
    public static let inventorySnapshotFileName = "inventory.json"

    public static func policyDatabasePath() -> String {
        resolvePath(
            environmentKey: "SANCTUARY_DB_PATH",
            fileName: policyDatabaseFileName,
            preferUserWhenBothExist: true
        )
    }

    public static func auditLogPath() -> String {
        resolvePath(
            environmentKey: "SANCTUARY_AUDIT_PATH",
            fileName: auditLogFileName,
            preferUserWhenBothExist: false
        )
    }

    public static func inventorySnapshotPath() -> String {
        resolvePath(
            environmentKey: "SANCTUARY_INVENTORY_SNAPSHOT_PATH",
            fileName: inventorySnapshotFileName,
            preferUserWhenBothExist: false
        )
    }

    public static func resolvePath(
        environmentKey: String,
        fileName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        effectiveUserID: uid_t = geteuid(),
        userHomeDirectory: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        createDirectory: (String) -> Void = { path in
            try? FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        },
        warning: (String) -> Void = { message in
            FileHandle.standardError.write(Data("Sanctuary path warning: \(message)\n".utf8))
        },
        preferUserWhenBothExist: Bool
    ) -> String {
        if let override = environment[environmentKey], !override.isEmpty {
            createDirectory(URL(fileURLWithPath: override).deletingLastPathComponent().path)
            return override
        }

        let userDirectory = userApplicationSupportDirectory(homeDirectory: userHomeDirectory)
        let userPath = URL(fileURLWithPath: userDirectory).appendingPathComponent(fileName).path
        let productionPath = URL(fileURLWithPath: productionDirectory).appendingPathComponent(fileName).path

        if preferUserWhenBothExist, fileExists(userPath), fileExists(productionPath) {
            warning(
                "both \(userPath) and \(productionPath) exist; using user policy DB. " +
                    "Consolidate policy state before packaging."
            )
            createDirectory(userDirectory)
            return userPath
        }

        if effectiveUserID == 0 {
            createDirectory(productionDirectory)
            return productionPath
        }

        createDirectory(userDirectory)
        return userPath
    }

    public static func userApplicationSupportDirectory(homeDirectory: String? = nil) -> String {
        let home = homeDirectory ?? consoleUserHomeDirectory() ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/sanctuary", isDirectory: true)
            .path
    }

    private static func consoleUserHomeDirectory() -> String? {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0 else {
            return nil
        }
        guard let passwd = getpwuid(info.st_uid), let directory = passwd.pointee.pw_dir else {
            return nil
        }
        return String(cString: directory)
    }
}

