// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public enum CurrentProcessExclusion {
    public static var currentPid: pid_t {
        getpid()
    }

    public static var currentProcessGroup: [pid_t] {
        processGroup(containing: currentPid)
    }

    public static func isSanctuaryExecutablePath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return [
            "sanctuary",
            "sanctuaryd",
            "sanctuary-cdpguard-test",
            "sanctuary-classify-live",
            "sanctuarymenubar"
        ].contains(name)
    }

    public static func filterAgentSnapshot(_ entries: [InventoryEntry]) -> [InventoryEntry] {
        let excluded = Set(currentProcessGroup)
        return entries.filter { !excluded.contains($0.pid) }
    }

    public static func filterPids(_ pids: [pid_t]) -> [pid_t] {
        let excluded = Set(currentProcessGroup)
        return pids.filter { !excluded.contains($0) }
    }

    static func filterAgentSnapshot(_ entries: [InventoryEntry], excluding excluded: Set<pid_t>) -> [InventoryEntry] {
        entries.filter { !excluded.contains($0.pid) }
    }

    static func filterPids(_ pids: [pid_t], excluding excluded: Set<pid_t>) -> [pid_t] {
        pids.filter { !excluded.contains($0) }
    }

    static func processGroup(
        containing rootPID: pid_t,
        listPIDs: () throws -> [pid_t] = { try DarwinProc().listPIDs() },
        parentPID: (pid_t) -> pid_t? = { liveParentPID($0) }
    ) -> [pid_t] {
        let pids = (try? listPIDs()) ?? []
        var parentByPID: [pid_t: pid_t] = [:]
        for pid in pids where pid > 0 {
            if let parent = parentPID(pid), parent > 0 {
                parentByPID[pid] = parent
            }
        }

        var excluded: Set<pid_t> = [rootPID]
        var changed = true
        while changed {
            changed = false
            for (pid, parent) in parentByPID where excluded.contains(parent) && !excluded.contains(pid) {
                excluded.insert(pid)
                changed = true
            }
        }
        return excluded.sorted()
    }

    private static func liveParentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written == MemoryLayout<proc_bsdinfo>.stride else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }
}
