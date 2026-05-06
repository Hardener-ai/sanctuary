// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public struct SocketEndpoint: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Address: Equatable, Hashable, Sendable {
        case ipv4([UInt8])
        case ipv6([UInt8])
    }

    public let address: Address
    public let port: UInt16

    public init(address: Address, port: UInt16) {
        self.address = address
        self.port = port
    }

    public init(ipv4 address: String, port: UInt16) throws {
        self.address = try Self.parse(address, family: AF_INET)
        self.port = port
    }

    public init(ipv6 address: String, port: UInt16) throws {
        self.address = try Self.parse(address, family: AF_INET6)
        self.port = port
    }

    init?(inSockInfo: in_sockinfo, useLocalAddress: Bool) {
        let rawPort = useLocalAddress ? inSockInfo.insi_lport : inSockInfo.insi_fport
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: rawPort))

        if inSockInfo.insi_vflag & UInt8(INI_IPV4) != 0 {
            let rawAddress = useLocalAddress
                ? inSockInfo.insi_laddr.ina_46.i46a_addr4.s_addr
                : inSockInfo.insi_faddr.ina_46.i46a_addr4.s_addr
            let bytes = withUnsafeBytes(of: rawAddress) { Array($0) }
            self.init(address: .ipv4(bytes), port: port)
            return
        }

        if inSockInfo.insi_vflag & UInt8(INI_IPV6) != 0 {
            let rawAddress = useLocalAddress
                ? inSockInfo.insi_laddr.ina_6
                : inSockInfo.insi_faddr.ina_6
            let bytes = withUnsafeBytes(of: rawAddress) { Array($0.prefix(16)) }
            self.init(address: .ipv6(bytes), port: port)
            return
        }

        return nil
    }

    public var description: String {
        "\(address.description):\(port)"
    }

    private static func parse(_ address: String, family: Int32) throws -> Address {
        let byteCount = family == AF_INET ? 4 : 16
        var bytes = Array(repeating: UInt8(0), count: byteCount)
        let result = bytes.withUnsafeMutableBytes { buffer in
            inet_pton(family, address, buffer.baseAddress)
        }

        guard result == 1 else {
            throw SocketEndpointError.invalidAddress(address)
        }

        return family == AF_INET ? .ipv4(bytes) : .ipv6(bytes)
    }
}

extension SocketEndpoint.Address: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .ipv4(bytes):
            return bytes.map(String.init).joined(separator: ".")
        case let .ipv6(bytes):
            return bytes.map { String(format: "%02x", $0) }.joined(separator: "")
        }
    }
}

public enum SocketEndpointError: Error, Equatable, Sendable {
    case invalidAddress(String)
}

public enum AttributionResult: Equatable, Sendable {
    case definite(pid_t)
    case ambiguous([pid_t])
    case unknown
}

public protocol PeerProcessAttributing: Sendable {
    func attribute(localEndpoint: SocketEndpoint, remoteEndpoint: SocketEndpoint) -> AttributionResult
}

public struct PeerProcessAttributor: PeerProcessAttributing {
    private let proc: any DarwinProcProviding
    private let latencyBudgetNanoseconds: UInt64

    public init(
        proc: any DarwinProcProviding = DarwinProc(),
        latencyBudgetNanoseconds: UInt64 = 10_000_000
    ) {
        self.proc = proc
        self.latencyBudgetNanoseconds = latencyBudgetNanoseconds
    }

    public func attribute(
        localEndpoint: SocketEndpoint,
        remoteEndpoint: SocketEndpoint
    ) -> AttributionResult {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed > latencyBudgetNanoseconds {
                let milliseconds = Double(elapsed) / 1_000_000
                debugPrint("Sanctuary PeerProcessAttributor exceeded 10ms budget: \(String(format: "%.3f", milliseconds))ms")
            }
        }

        let pids: [pid_t]
        do {
            pids = try proc.listPIDs()
        } catch {
            return .unknown
        }

        var matches: [pid_t] = []

        for pid in pids {
            let descriptors: [ProcessFileDescriptor]
            do {
                descriptors = try proc.listFileDescriptors(pid: pid)
            } catch {
                continue
            }

            for descriptor in descriptors where descriptor.type == DarwinProc.socketFileDescriptorType {
                guard let info = try? proc.socketInfo(pid: pid, fd: descriptor.fd) else {
                    continue
                }

                guard
                    info.protocolNumber == DarwinProc.tcpProtocolNumber,
                    info.tcpState == DarwinProc.establishedTCPState,
                    info.localEndpoint == localEndpoint,
                    info.remoteEndpoint == remoteEndpoint
                else {
                    continue
                }

                matches.append(pid)
            }
        }

        let uniqueMatches = Array(Set(matches)).sorted()
        switch uniqueMatches.count {
        case 0:
            return .unknown
        case 1:
            return .definite(uniqueMatches[0])
        default:
            return .ambiguous(uniqueMatches)
        }
    }
}
