// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum AnchorState: Equatable, Sendable {
    case present(rules: [String])
    case missing
    case modified(actualRules: [String], expectedRules: [String])
    case pfctlError(String)
}

public enum PFAnchorValidator {
    public static func currentAnchorState(anchor: String) -> AnchorState {
        currentAnchorState(anchor: anchor, expectedRules: nil, commandRunner: ProcessCommandRunner())
    }

    public static func currentAnchorState(anchor: String, expectedRules: String) -> AnchorState {
        currentAnchorState(anchor: anchor, expectedRules: expectedRules, commandRunner: ProcessCommandRunner())
    }

    static func currentAnchorState(
        anchor: String,
        expectedRules: String?,
        commandRunner: any CommandRunning
    ) -> AnchorState {
        do {
            let result = try commandRunner.run(executable: "/sbin/pfctl", arguments: ["-a", anchor, "-s", "nat"])
            return state(from: result, expectedRules: expectedRules)
        } catch {
            return .pfctlError(String(describing: error))
        }
    }

    static func state(from result: CommandResult, expectedRules: String? = nil) -> AnchorState {
        guard result.exitCode == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .pfctlError(reason.isEmpty ? "pfctl exited \(result.exitCode)" : reason)
        }

        let actual = normalizedRules(result.stdout)
        guard !actual.isEmpty else {
            return .missing
        }

        guard let expectedRules else {
            return .present(rules: actual)
        }

        let expected = normalizedRules(expectedRules)
        if actual == expected {
            return .present(rules: actual)
        }
        return .modified(actualRules: actual, expectedRules: expected)
    }

    static func normalizedRules(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { line in
                line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .replacingOccurrences(of: "port = ", with: "port ")
            }
            .filter { !$0.isEmpty }
            .sorted()
    }
}
