// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SanctuaryCore

let runtime = try SanctuaryDaemonRuntime.live()

try runtime.start()
print(
    "sanctuaryd started; watching \(runtime.folderWatchPathCount) protected folder(s), " +
        "\(runtime.extensionWatchPathCount) extension storage path(s)"
)
fflush(stdout)

let stopSemaphore = DispatchSemaphore(value: 0)
let signalQueue = DispatchQueue(label: "ai.hardener.sanctuary.daemon.signals")

let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
signal(SIGTERM, SIG_IGN)
signalSource.setEventHandler {
    stopSemaphore.signal()
}
signalSource.resume()

let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
signal(SIGINT, SIG_IGN)
interruptSource.setEventHandler {
    stopSemaphore.signal()
}
interruptSource.resume()

stopSemaphore.wait()
let shutdownGroup = DispatchGroup()
shutdownGroup.enter()
DispatchQueue.global(qos: .utility).async {
    runtime.stop()
    shutdownGroup.leave()
}

if shutdownGroup.wait(timeout: .now() + 5) == .timedOut {
    fputs("sanctuaryd warning: clean shutdown exceeded 5 seconds\n", stderr)
    exit(1)
}
