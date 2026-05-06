// SPDX-License-Identifier: AGPL-3.0-only
// KERN_PROCARGS2 buffers contain argv strings followed by environment strings.
// Environment values may include API keys and wallet secrets, so this parser
// only returns variable names. Values are split off at the first "=" and are
// never exposed by this API.
import Foundation

public struct ProcArgs: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environmentVarNames: Set<String>

    public init(executablePath: String, arguments: [String], environmentVarNames: Set<String>) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environmentVarNames = environmentVarNames
    }
}

public enum ProcArgsParser {
    private static let maximumReasonableArgumentCount = 100_000

    public static func parse(_ data: Data) -> ProcArgs? {
        parse(Array(data))
    }

    public static func parse(_ bytes: [UInt8]) -> ProcArgs? {
        guard bytes.count >= 4 else {
            return nil
        }

        let argc = Int(
            Int32(bitPattern:
                UInt32(bytes[0]) |
                (UInt32(bytes[1]) << 8) |
                (UInt32(bytes[2]) << 16) |
                (UInt32(bytes[3]) << 24)
            )
        )
        guard argc >= 0, argc <= maximumReasonableArgumentCount else {
            return nil
        }

        var offset = 4
        guard let executablePath = readCString(bytes, offset: &offset), !executablePath.isEmpty else {
            return nil
        }

        skipNULs(bytes, offset: &offset)

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = readCString(bytes, offset: &offset) else {
                return nil
            }
            arguments.append(argument)
            skipNULs(bytes, offset: &offset)
        }

        var names: Set<String> = []
        while offset < bytes.count {
            if let name = readEnvironmentName(bytes, offset: &offset) {
                names.insert(name)
            }
            skipNULs(bytes, offset: &offset)
        }

        return ProcArgs(
            executablePath: executablePath,
            arguments: arguments,
            environmentVarNames: names
        )
    }

    private static func readCString(_ bytes: [UInt8], offset: inout Int) -> String? {
        guard offset < bytes.count else {
            return nil
        }

        let start = offset
        while offset < bytes.count, bytes[offset] != 0 {
            offset += 1
        }
        guard offset < bytes.count else {
            return nil
        }

        let stringBytes = bytes[start..<offset]
        offset += 1
        return String(bytes: stringBytes, encoding: .utf8)
    }

    private static func skipNULs(_ bytes: [UInt8], offset: inout Int) {
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }
    }

    private static func readEnvironmentName(_ bytes: [UInt8], offset: inout Int) -> String? {
        guard offset < bytes.count else {
            return nil
        }

        let start = offset
        var equals: Int?
        while offset < bytes.count, bytes[offset] != 0 {
            if bytes[offset] == UInt8(ascii: "="), equals == nil {
                equals = offset
            }
            offset += 1
        }
        guard offset < bytes.count else {
            return nil
        }

        offset += 1
        guard let equals, equals > start else {
            return nil
        }
        return String(bytes: bytes[start..<equals], encoding: .utf8)
    }
}
