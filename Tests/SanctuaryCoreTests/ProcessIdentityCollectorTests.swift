// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import SanctuaryCore

struct ProcessIdentityCollectorTests {
    @Test func returnsNilWhenExecutablePathMissing() {
        let collector = ProcessIdentityCollector(darwinProc: adapter(paths: [:]), codeSigningInspector: MockCodeSigningInspector())

        #expect(collector.collect(pid: 42) == nil)
    }

    @Test func returnsPartialIdentityWhenOptionalFieldsAreMissing() throws {
        let collector = ProcessIdentityCollector(darwinProc: adapter(paths: [42: "/bin/zsh"]), codeSigningInspector: MockCodeSigningInspector())

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.pid == 42)
        #expect(identity.executablePath.hasSuffix("/bin/zsh"))
        #expect(identity.arguments.isEmpty)
        #expect(identity.environmentVars.isEmpty)
    }

    @Test func collectsArgumentsAndEnvironmentNames() throws {
        let collector = ProcessIdentityCollector(
            darwinProc: adapter(
                paths: [42: "/usr/bin/python3"],
                args: [42: ProcArgs(executablePath: "/usr/bin/python3", arguments: ["python3", "-m", "anthropic"], environmentVarNames: ["OPENAI_API_KEY"])]
            ),
            codeSigningInspector: MockCodeSigningInspector()
        )

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.arguments == ["python3", "-m", "anthropic"])
        #expect(identity.environmentVars == ["OPENAI_API_KEY"])
    }

    @Test func collectsCodeSigningInfo() throws {
        let collector = ProcessIdentityCollector(
            darwinProc: adapter(paths: [42: "/Applications/Cursor.app/Contents/MacOS/Cursor"]),
            codeSigningInspector: MockCodeSigningInspector(infos: [42: CodeSigningInfo(signingIdentifier: "com.cursor.Cursor", teamIdentifier: "CURSORAI")])
        )

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.codeSigningIdentifier == "com.cursor.Cursor")
        #expect(identity.teamIdentifier == "CURSORAI")
    }

    @Test func unsignedCodeSigningInfoKeepsNilIdentifiers() throws {
        let collector = ProcessIdentityCollector(
            darwinProc: adapter(paths: [42: "/tmp/unsigned"]),
            codeSigningInspector: MockCodeSigningInspector(infos: [42: CodeSigningInfo(signingIdentifier: nil, teamIdentifier: nil)])
        )

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.codeSigningIdentifier == nil)
        #expect(identity.teamIdentifier == nil)
    }

    @Test func collectsCWD() throws {
        let collector = ProcessIdentityCollector(
            darwinProc: adapter(paths: [42: "/bin/zsh"], cwd: [42: "/Users/tg/Projects/sanctuary/"]),
            codeSigningInspector: MockCodeSigningInspector()
        )

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.cwd == ExtensionPathMaterializer.normalize("/Users/tg/Projects/sanctuary"))
    }

    @Test func walksParentChainUpToAncestors() throws {
        let collector = ProcessIdentityCollector(
            darwinProc: adapter(
                paths: [42: "/bin/zsh", 7: "/usr/local/bin/claude", 1: "/sbin/launchd"],
                parents: [42: 7, 7: 1]
            ),
            codeSigningInspector: MockCodeSigningInspector()
        )

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.parentChain.map(\.pid) == [7, 1])
        #expect(identity.parentChain.map(\.executablePath).last?.hasSuffix("/sbin/launchd") == true)
    }

    @Test func stopsParentWalkAfterEightAncestors() throws {
        var paths: [pid_t: String] = [100: "/bin/leaf"]
        var parents: [pid_t: pid_t] = [:]
        for pid in 1...10 {
            paths[pid_t(pid)] = "/bin/p\(pid)"
        }
        parents[100] = 10
        for pid in stride(from: 10, through: 2, by: -1) {
            parents[pid_t(pid)] = pid_t(pid - 1)
        }

        let collector = ProcessIdentityCollector(darwinProc: adapter(paths: paths, parents: parents), codeSigningInspector: MockCodeSigningInspector())
        let identity = try #require(collector.collect(pid: 100))

        #expect(identity.parentChain.count == 8)
        #expect(identity.parentChain.first?.pid == 10)
        #expect(identity.parentChain.last?.pid == 3)
    }

    @Test func avoidsParentCycles() throws {
        let collector = ProcessIdentityCollector(
            darwinProc: adapter(paths: [42: "/bin/a", 7: "/bin/b"], parents: [42: 7, 7: 42]),
            codeSigningInspector: MockCodeSigningInspector()
        )

        let identity = try #require(collector.collect(pid: 42))
        #expect(identity.parentChain.map(\.pid) == [7])
    }

    @Test func classifierClassifyPIDDelegatesThroughCollector() {
        let classifier = AgentClassifier(
            knownAgents: [KnownAgent(id: "claude-code", displayName: "Claude Code", executableNames: ["claude"])],
            processIdentityCollector: FixedProcessIdentityCollector(identities: [
                42: ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/claude")
            ])
        )

        #expect(classifier.classify(pid: 42) == .agent(reason: .knownList("Claude Code"), confidence: .medium))
        #expect(classifier.classify(pid: 99) == .notAgent)
    }
}

private func adapter(
    paths: [pid_t: String],
    parents: [pid_t: pid_t] = [:],
    cwd: [pid_t: String] = [:],
    args: [pid_t: ProcArgs] = [:]
) -> DarwinProcAdapter {
    DarwinProcAdapter(
        executablePath: { paths[$0] },
        parentPID: { parents[$0] },
        cwd: { cwd[$0] },
        procArgs: { args[$0] }
    )
}

private struct MockCodeSigningInspector: CodeSigningInspecting {
    var infos: [pid_t: CodeSigningInfo] = [:]

    func inspect(pid: pid_t) -> CodeSigningInfo? {
        infos[pid]
    }
}

private struct FixedProcessIdentityCollector: ProcessIdentityCollecting {
    let identities: [pid_t: ProcessIdentity]

    func collect(pid: pid_t) -> ProcessIdentity? {
        identities[pid]
    }
}
