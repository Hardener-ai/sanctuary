// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Darwin
import Foundation

public struct DarwinProcAdapter: Sendable {
    public static let live = DarwinProcAdapter()

    private let executablePathProvider: @Sendable (pid_t) -> String?
    private let parentPIDProvider: @Sendable (pid_t) -> pid_t?
    private let cwdProvider: @Sendable (pid_t) -> String?
    private let procArgsProvider: @Sendable (pid_t) -> ProcArgs?

    public init(
        executablePath: (@Sendable (pid_t) -> String?)? = nil,
        parentPID: (@Sendable (pid_t) -> pid_t?)? = nil,
        cwd: (@Sendable (pid_t) -> String?)? = nil,
        procArgs: (@Sendable (pid_t) -> ProcArgs?)? = nil
    ) {
        self.executablePathProvider = executablePath ?? { DarwinProcAdapter.liveExecutablePath(pid: $0) }
        self.parentPIDProvider = parentPID ?? { DarwinProcAdapter.liveParentPID(pid: $0) }
        self.cwdProvider = cwd ?? { DarwinProcAdapter.liveCWD(pid: $0) }
        self.procArgsProvider = procArgs ?? { DarwinProcAdapter.liveProcArgs(pid: $0) }
    }

    public func executablePath(pid: pid_t) -> String? {
        executablePathProvider(pid).flatMap(Self.realPath)
    }

    public func parentPID(pid: pid_t) -> pid_t? {
        parentPIDProvider(pid)
    }

    public func cwd(pid: pid_t) -> String? {
        cwdProvider(pid).map(ExtensionPathMaterializer.normalize)
    }

    public func procArgs(pid: pid_t) -> ProcArgs? {
        procArgsProvider(pid)
    }

    private static func liveExecutablePath(pid: pid_t) -> String? {
        var buffer = Array(repeating: CChar(0), count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func liveParentPID(pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written == MemoryLayout<proc_bsdinfo>.stride, info.pbi_ppid > 0 else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }

    private static func liveCWD(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written == MemoryLayout<proc_vnodepathinfo>.stride else {
            return nil
        }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer -> String? in
            let chars = buffer.bindMemory(to: CChar.self)
            guard let base = chars.baseAddress else {
                return nil
            }
            let path = String(cString: base)
            return path.isEmpty ? nil : path
        }
    }

    private static func liveProcArgs(pid: pid_t) -> ProcArgs? {
        let maxArgBytes = max(Int(sysconf(_SC_ARG_MAX)), 4096)
        var buffer = Array(repeating: UInt8(0), count: maxArgBytes)
        defer {
            buffer.withUnsafeMutableBufferPointer { pointer in
                pointer.initialize(repeating: 0)
            }
        }

        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 0, size <= buffer.count else {
            return nil
        }

        return ProcArgsParser.parse(Array(buffer.prefix(size)))
    }

    private static func realPath(_ path: String) -> String? {
        let resolved = realpath(path, nil)
        defer {
            if let resolved {
                free(resolved)
            }
        }
        guard let resolved else {
            return ExtensionPathMaterializer.normalize(path)
        }
        return ExtensionPathMaterializer.normalize(String(cString: resolved))
    }
}

public protocol ProcessIdentityCollecting: Sendable {
    func collect(pid: pid_t) -> ProcessIdentity?
}

public final class ProcessIdentityCollector: ProcessIdentityCollecting, @unchecked Sendable {
    private let darwinProc: DarwinProcAdapter
    private let codeSigningInspector: any CodeSigningInspecting

    public init(
        darwinProc: DarwinProcAdapter = .live,
        codeSigningInspector: any CodeSigningInspecting = CodeSigningInspector()
    ) {
        self.darwinProc = darwinProc
        self.codeSigningInspector = codeSigningInspector
    }

    public func collect(pid: pid_t) -> ProcessIdentity? {
        collect(pid: pid, remainingDepth: 8, visited: [])
    }

    private func collect(pid: pid_t, remainingDepth: Int, visited: Set<pid_t>) -> ProcessIdentity? {
        guard !visited.contains(pid), let executablePath = darwinProc.executablePath(pid: pid) else {
            return nil
        }

        let procArgs = darwinProc.procArgs(pid: pid)
        let signingInfo = codeSigningInspector.inspect(pid: pid)
        let parentChain: [ProcessIdentity]
        if remainingDepth > 0,
           let parentPID = darwinProc.parentPID(pid: pid),
           parentPID > 0,
           parentPID != pid,
           let parent = collect(pid: parentPID, remainingDepth: remainingDepth - 1, visited: visited.union([pid])) {
            parentChain = [parent] + parent.parentChain
        } else {
            parentChain = []
        }

        return ProcessIdentity(
            pid: pid,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier(pid: pid),
            codeSigningIdentifier: signingInfo?.signingIdentifier,
            teamIdentifier: signingInfo?.teamIdentifier,
            parentChain: parentChain,
            environmentVars: procArgs?.environmentVarNames ?? [],
            cwd: darwinProc.cwd(pid: pid),
            arguments: procArgs?.arguments ?? [],
            loadedModulePaths: [],
            packageDependencyNames: []
        )
    }

    private func bundleIdentifier(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
