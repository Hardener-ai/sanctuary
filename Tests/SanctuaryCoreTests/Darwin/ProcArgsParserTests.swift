// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ProcArgsParserTests {
    @Test func parsesExecutableArgumentsAndEnvironmentNames() throws {
        let args = try #require(ProcArgsParser.parse(buffer(argc: 2, executable: "/bin/zsh", strings: ["zsh", "-l", "PATH=/usr/bin", "HOME=/Users/tg"])))

        #expect(args.executablePath == "/bin/zsh")
        #expect(args.arguments == ["zsh", "-l"])
        #expect(args.environmentVarNames == ["PATH", "HOME"])
    }

    @Test func parsesNoEnvironmentCase() throws {
        let args = try #require(ProcArgsParser.parse(buffer(argc: 1, executable: "/usr/bin/true", strings: ["true"])))

        #expect(args.arguments == ["true"])
        #expect(args.environmentVarNames.isEmpty)
    }

    @Test func toleratesAlignmentPaddingAfterExecutablePath() throws {
        var bytes = buffer(argc: 1, executable: "/bin/sh", strings: [])
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: cString("sh"))

        let args = try #require(ProcArgsParser.parse(bytes))
        #expect(args.arguments == ["sh"])
    }

    @Test func malformedBufferWithoutArgcReturnsNil() {
        #expect(ProcArgsParser.parse(Data([1, 2, 3])) == nil)
    }

    @Test func malformedExecutableWithoutNULTerminatorReturnsNil() {
        var bytes = littleEndianArgc(1)
        bytes.append(contentsOf: Array("/bin/sh".utf8))

        #expect(ProcArgsParser.parse(bytes) == nil)
    }

    @Test func malformedTooFewArgumentStringsReturnsNil() {
        #expect(ProcArgsParser.parse(buffer(argc: 2, executable: "/bin/sh", strings: ["sh"])) == nil)
    }

    @Test func veryLargeArgumentCountReturnsNil() {
        var bytes = littleEndianArgc(100_001)
        bytes.append(contentsOf: cString("/bin/sh"))
        bytes.append(contentsOf: cString("sh"))

        #expect(ProcArgsParser.parse(bytes) == nil)
    }

    @Test func privacyAuditNamesNeverContainEqualsOrValues() throws {
        let args = try #require(
            ProcArgsParser.parse(
                buffer(
                    argc: 1,
                    executable: "/usr/bin/python3",
                    strings: [
                        "python3",
                        "OPENAI_API_KEY=sk-secret=value-with-equals",
                        "ANTHROPIC_API_KEY=another-secret",
                        "EMPTY_VALUE="
                    ]
                )
            )
        )

        #expect(args.environmentVarNames == ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "EMPTY_VALUE"])
        #expect(args.environmentVarNames.allSatisfy { !$0.contains("=") })
        #expect(!args.environmentVarNames.contains("sk-secret=value-with-equals"))
        #expect(!args.environmentVarNames.contains("another-secret"))
    }

    @Test func ignoresEnvironmentStringsWithoutEquals() throws {
        let args = try #require(ProcArgsParser.parse(buffer(argc: 1, executable: "/bin/sh", strings: ["sh", "NOT_ENV", "PATH=/bin"])))

        #expect(args.environmentVarNames == ["PATH"])
    }
}

private func buffer(argc: Int32, executable: String, strings: [String]) -> Data {
    var bytes = littleEndianArgc(argc)
    bytes.append(contentsOf: cString(executable))
    bytes.append(0)
    while bytes.count % 8 != 0 {
        bytes.append(0)
    }
    for string in strings {
        bytes.append(contentsOf: cString(string))
    }
    return Data(bytes)
}

private func littleEndianArgc(_ argc: Int32) -> [UInt8] {
    let value = UInt32(bitPattern: argc)
    return [
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff)
    ]
}

private func cString(_ value: String) -> [UInt8] {
    Array(value.utf8) + [0]
}
