// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import SanctuaryCore

struct PeerProcessAttributorTests {
    @Test func singleMatchingPIDIsDefinite() throws {
        let local = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let remote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let proc = MockDarwinProc(
            pids: [100],
            descriptorsByPID: [100: [.socket(7)]],
            socketsByPIDAndFD: [[100, 7]: .tcp(local: local, remote: remote)]
        )

        #expect(PeerProcessAttributor(proc: proc).attribute(localEndpoint: local, remoteEndpoint: remote) == .definite(100))
    }

    @Test func twoMatchingPIDsAreAmbiguous() throws {
        let local = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let remote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let proc = MockDarwinProc(
            pids: [100, 101],
            descriptorsByPID: [100: [.socket(7)], 101: [.socket(8)]],
            socketsByPIDAndFD: [
                [100, 7]: .tcp(local: local, remote: remote),
                [101, 8]: .tcp(local: local, remote: remote)
            ]
        )

        #expect(PeerProcessAttributor(proc: proc).attribute(localEndpoint: local, remoteEndpoint: remote) == .ambiguous([100, 101]))
    }

    @Test func noMatchingPIDsAreUnknown() throws {
        let targetLocal = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let targetRemote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let otherLocal = try SocketEndpoint(ipv4: "127.0.0.1", port: 9333)
        let proc = MockDarwinProc(
            pids: [100],
            descriptorsByPID: [100: [.socket(7)]],
            socketsByPIDAndFD: [[100, 7]: .tcp(local: otherLocal, remote: targetRemote)]
        )

        #expect(PeerProcessAttributor(proc: proc).attribute(localEndpoint: targetLocal, remoteEndpoint: targetRemote) == .unknown)
    }

    @Test func closedSocketBetweenEnumerateAndInspectDoesNotCrash() throws {
        let local = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let remote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let proc = MockDarwinProc(
            pids: [100],
            descriptorsByPID: [100: [.socket(7)]],
            socketErrorsByPIDAndFD: [[100, 7]: .processUnavailable]
        )

        #expect(PeerProcessAttributor(proc: proc).attribute(localEndpoint: local, remoteEndpoint: remote) == .unknown)
    }

    @Test func permissionDeniedPIDIsSkippedAndScanContinues() throws {
        let local = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let remote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let proc = MockDarwinProc(
            pids: [100, 101],
            descriptorsByPID: [101: [.socket(8)]],
            descriptorErrorsByPID: [100: .permissionDenied],
            socketsByPIDAndFD: [[101, 8]: .tcp(local: local, remote: remote)]
        )

        #expect(PeerProcessAttributor(proc: proc).attribute(localEndpoint: local, remoteEndpoint: remote) == .definite(101))
    }

    @Test func syntheticTwoHundredPIDScanMeetsLatencyBudget() throws {
        let local = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let remote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let pids = (1...200).map(pid_t.init)
        let descriptors = Dictionary(uniqueKeysWithValues: pids.map { ($0, [ProcessFileDescriptor.socket(3)]) })
        let sockets = Dictionary(uniqueKeysWithValues: pids.map { pid in
            (PIDFDKey(pid: pid, fd: 3), ProcessSocketInfo.tcp(local: local, remote: remote))
        })
        let proc = MockDarwinProc(pids: pids, descriptorsByPID: descriptors, socketsByPIDAndFD: sockets)
        let attributor = PeerProcessAttributor(proc: proc)
        var durations: [Double] = []

        for _ in 0..<100 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = attributor.attribute(localEndpoint: local, remoteEndpoint: remote)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            durations.append(Double(elapsed) / 1_000_000)
        }

        let p95 = durations.sorted()[94]
        print("PeerProcessAttributor synthetic p95 latency: \(String(format: "%.3f", p95))ms")
        #expect(p95 < 10)
    }

    @Test func ipv4AndIPv6EndpointsBothMatchCorrectly() throws {
        let ipv4Local = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let ipv4Remote = try SocketEndpoint(ipv4: "127.0.0.1", port: 54321)
        let ipv6Local = try SocketEndpoint(ipv6: "::1", port: 9222)
        let ipv6Remote = try SocketEndpoint(ipv6: "::1", port: 54321)
        let proc = MockDarwinProc(
            pids: [100, 101],
            descriptorsByPID: [100: [.socket(7)], 101: [.socket(8)]],
            socketsByPIDAndFD: [
                [100, 7]: .tcp(local: ipv4Local, remote: ipv4Remote),
                [101, 8]: .tcp(local: ipv6Local, remote: ipv6Remote)
            ]
        )
        let attributor = PeerProcessAttributor(proc: proc)

        #expect(attributor.attribute(localEndpoint: ipv4Local, remoteEndpoint: ipv4Remote) == .definite(100))
        #expect(attributor.attribute(localEndpoint: ipv6Local, remoteEndpoint: ipv6Remote) == .definite(101))
    }

    @Test func endpointNormalizationDistinguishesIPv4MappedIPv6AndIPv6Loopback() throws {
        let ipv4 = try SocketEndpoint(ipv4: "127.0.0.1", port: 9222)
        let mapped = try SocketEndpoint(ipv6: "::ffff:127.0.0.1", port: 9222)
        let ipv6 = try SocketEndpoint(ipv6: "::1", port: 9222)

        #expect(ipv4 != mapped)
        #expect(mapped != ipv6)
        #expect(ipv4 != ipv6)
    }
}

private struct MockDarwinProc: DarwinProcProviding {
    let pids: [pid_t]
    let descriptorsByPID: [pid_t: [ProcessFileDescriptor]]
    let descriptorErrorsByPID: [pid_t: DarwinProcError]
    let socketsByPIDAndFD: [PIDFDKey: ProcessSocketInfo]
    let socketErrorsByPIDAndFD: [PIDFDKey: DarwinProcError]

    init(
        pids: [pid_t],
        descriptorsByPID: [pid_t: [ProcessFileDescriptor]] = [:],
        descriptorErrorsByPID: [pid_t: DarwinProcError] = [:],
        socketsByPIDAndFD: [PIDFDKey: ProcessSocketInfo] = [:],
        socketErrorsByPIDAndFD: [PIDFDKey: DarwinProcError] = [:]
    ) {
        self.pids = pids
        self.descriptorsByPID = descriptorsByPID
        self.descriptorErrorsByPID = descriptorErrorsByPID
        self.socketsByPIDAndFD = socketsByPIDAndFD
        self.socketErrorsByPIDAndFD = socketErrorsByPIDAndFD
    }

    func listPIDs() throws -> [pid_t] {
        pids
    }

    func listFileDescriptors(pid: pid_t) throws -> [ProcessFileDescriptor] {
        if let error = descriptorErrorsByPID[pid] {
            throw error
        }
        return descriptorsByPID[pid] ?? []
    }

    func socketInfo(pid: pid_t, fd: Int32) throws -> ProcessSocketInfo? {
        let key = PIDFDKey(pid: pid, fd: fd)
        if let error = socketErrorsByPIDAndFD[key] {
            throw error
        }
        return socketsByPIDAndFD[key]
    }
}

private struct PIDFDKey: Hashable, ExpressibleByArrayLiteral {
    let pid: pid_t
    let fd: Int32

    init(pid: pid_t, fd: Int32) {
        self.pid = pid
        self.fd = fd
    }

    init(arrayLiteral elements: Int32...) {
        precondition(elements.count == 2)
        self.pid = pid_t(elements[0])
        self.fd = elements[1]
    }
}

private extension ProcessFileDescriptor {
    static func socket(_ fd: Int32) -> ProcessFileDescriptor {
        ProcessFileDescriptor(fd: fd, type: DarwinProc.socketFileDescriptorType)
    }
}

private extension ProcessSocketInfo {
    static func tcp(
        local: SocketEndpoint,
        remote: SocketEndpoint,
        state: Int32 = DarwinProc.establishedTCPState
    ) -> ProcessSocketInfo {
        ProcessSocketInfo(
            localEndpoint: local,
            remoteEndpoint: remote,
            protocolNumber: DarwinProc.tcpProtocolNumber,
            tcpState: state
        )
    }
}
