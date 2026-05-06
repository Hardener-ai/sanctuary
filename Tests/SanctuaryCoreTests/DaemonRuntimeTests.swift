// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct DaemonRuntimeTests {
    @Test func runtimeStartsAndStopsFolderExtensionAndInventoryServices() throws {
        let folder = RecordingDaemonService(name: "protected-folder-watcher")
        let extensionStorage = RecordingDaemonService(name: "extension-storage-protection")
        let extensionPoller = RecordingDaemonService(name: "extension-storage-read-poller")
        let inventory = RecordingDaemonService(name: "service-inventory")
        let runtime = SanctuaryDaemonRuntime(
            services: [folder, extensionStorage, extensionPoller, inventory],
            folderWatchPathCount: 2,
            extensionWatchPathCount: 3
        )

        try runtime.start()
        runtime.stop()

        #expect(runtime.serviceNames == [
            "protected-folder-watcher",
            "extension-storage-protection",
            "extension-storage-read-poller",
            "service-inventory"
        ])
        #expect(runtime.folderWatchPathCount == 2)
        #expect(runtime.extensionWatchPathCount == 3)
        #expect(folder.events == ["start", "stop"])
        #expect(extensionStorage.events == ["start", "stop"])
        #expect(extensionPoller.events == ["start", "stop"])
        #expect(inventory.events == ["start", "stop"])
    }

    @Test func runtimeStopsAlreadyStartedServicesWhenLaterStartFails() throws {
        let first = RecordingDaemonService(name: "first")
        let second = RecordingDaemonService(name: "second", startError: DaemonRuntimeTestError.startFailed)
        let runtime = SanctuaryDaemonRuntime(services: [first, second])

        #expect(throws: DaemonRuntimeTestError.startFailed) {
            try runtime.start()
        }
        #expect(first.events == ["start", "stop"])
        #expect(second.events == [])
    }
}

private enum DaemonRuntimeTestError: Error, Equatable {
    case startFailed
}

private final class RecordingDaemonService: SanctuaryDaemonService, @unchecked Sendable {
    let name: String
    private let startError: DaemonRuntimeTestError?
    private(set) var events: [String] = []

    init(name: String, startError: DaemonRuntimeTestError? = nil) {
        self.name = name
        self.startError = startError
    }

    func start() throws {
        if let startError {
            throw startError
        }
        events.append("start")
    }

    func stop() {
        events.append("stop")
    }
}
