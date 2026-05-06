// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public func currentEffectiveUserID() -> uid_t {
    geteuid()
}

public struct ProcessFileDescriptor: Equatable, Sendable {
    public let fd: Int32
    public let type: Int32

    public init(fd: Int32, type: Int32) {
        self.fd = fd
        self.type = type
    }
}

public struct ProcessSocketInfo: Equatable, Sendable {
    public let localEndpoint: SocketEndpoint
    public let remoteEndpoint: SocketEndpoint
    public let protocolNumber: Int32
    public let tcpState: Int32

    public init(
        localEndpoint: SocketEndpoint,
        remoteEndpoint: SocketEndpoint,
        protocolNumber: Int32,
        tcpState: Int32
    ) {
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.protocolNumber = protocolNumber
        self.tcpState = tcpState
    }
}

public enum DarwinProcError: Error, Equatable, Sendable {
    case permissionDenied
    case processUnavailable
    case syscallFailed(String)
}

public protocol DarwinProcProviding: Sendable {
    func listPIDs() throws -> [pid_t]
    func listFileDescriptors(pid: pid_t) throws -> [ProcessFileDescriptor]
    func socketInfo(pid: pid_t, fd: Int32) throws -> ProcessSocketInfo?
}

public struct DarwinProc: DarwinProcProviding {
    public static let socketFileDescriptorType = Int32(PROX_FDTYPE_SOCKET)
    public static let tcpProtocolNumber = Int32(IPPROTO_TCP)
    public static let establishedTCPState = Int32(TSI_S_ESTABLISHED)

    public init() {}

    public func listPIDs() throws -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var pids = Array(repeating: pid_t(0), count: capacity)
        let writtenBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }

        guard writtenBytes >= 0 else {
            throw DarwinProcError.syscallFailed("proc_listpids")
        }

        return pids.prefix(Int(writtenBytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    public func listFileDescriptors(pid: pid_t) throws -> [ProcessFileDescriptor] {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if byteCount <= 0 {
            throw mapErrno("proc_pidinfo(PROC_PIDLISTFDS)")
        }

        let capacity = Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
        var descriptors = Array(repeating: proc_fdinfo(), count: capacity)
        let writtenBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }

        if writtenBytes <= 0 {
            throw mapErrno("proc_pidinfo(PROC_PIDLISTFDS)")
        }

        return descriptors
            .prefix(Int(writtenBytes) / MemoryLayout<proc_fdinfo>.stride)
            .map { ProcessFileDescriptor(fd: Int32($0.proc_fd), type: Int32($0.proc_fdtype)) }
    }

    public func socketInfo(pid: pid_t, fd: Int32) throws -> ProcessSocketInfo? {
        var info = socket_fdinfo()
        let writtenBytes = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, buffer.baseAddress, Int32(buffer.count))
        }

        if writtenBytes <= 0 {
            throw mapErrno("proc_pidfdinfo(PROC_PIDFDSOCKETINFO)")
        }

        guard info.psi.soi_kind == SOCKINFO_TCP else {
            return nil
        }

        let tcpInfo = info.psi.soi_proto.pri_tcp
        guard
            let local = SocketEndpoint(inSockInfo: tcpInfo.tcpsi_ini, useLocalAddress: true),
            let remote = SocketEndpoint(inSockInfo: tcpInfo.tcpsi_ini, useLocalAddress: false)
        else {
            return nil
        }

        return ProcessSocketInfo(
            localEndpoint: local,
            remoteEndpoint: remote,
            protocolNumber: Int32(info.psi.soi_protocol),
            tcpState: Int32(tcpInfo.tcpsi_state)
        )
    }

    private func mapErrno(_ call: String) -> DarwinProcError {
        switch errno {
        case EACCES, EPERM:
            return .permissionDenied
        case ESRCH, EBADF, ENOENT:
            return .processUnavailable
        default:
            return .syscallFailed(call)
        }
    }
}
