// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public final class AuditTailReader: @unchecked Sendable {
    private let path: String
    private let maxBytes: Int
    private let now: @Sendable () -> Date

    public init(path: String, maxBytes: Int = 32_768, now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.maxBytes = maxBytes
        self.now = now
    }

    public func recentEntries(within: TimeInterval = 3600, limit: Int = 5) -> [ActivityEntry] {
        guard limit > 0, let contents = tailContents() else {
            return []
        }

        let currentDate = now()
        var entries: [ActivityEntry] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let entry = Self.parseEntryLine(String(rawLine)),
                  ActivityRenderer.shouldRender(entry)
            else {
                continue
            }
            let activity = ActivityRenderer.summarize(entry, now: currentDate)
            guard currentDate.timeIntervalSince(activity.timestamp) <= within else {
                continue
            }
            entries.append(activity)
            if entries.count == limit {
                break
            }
        }
        return entries
    }

    public static func parseEntryLine(_ line: String) -> AuditEntry? {
        let data: Data
        if let parsed = AuditLog.parseSignedLine(line) {
            data = parsed.entryJSON
        } else {
            data = Data(line.utf8)
        }
        return try? JSONDecoder().decode(AuditEntry.self, from: data)
    }

    private func tailContents() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let bytesToRead = UInt64(max(0, maxBytes))
        let start = size > bytesToRead ? size - bytesToRead : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
