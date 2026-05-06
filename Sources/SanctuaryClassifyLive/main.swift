// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import SanctuaryCore

let arguments = Array(CommandLine.arguments.dropFirst())
let collector = ProcessIdentityCollector()
let classifier = AgentClassifier.live(processIdentityCollector: collector)
let proc = DarwinProc()

func describe(_ verdict: AgentVerdict) -> String {
    switch verdict {
    case let .agent(reason, confidence):
        return ".agent(\(reason), \(confidence))"
    case let .suspicious(reason):
        return ".suspicious(\(reason))"
    case .notAgent:
        return ".notAgent"
    }
}

func printClassification(pid: pid_t) {
    guard let identity = collector.collect(pid: pid) else {
        return
    }

    print("\(pid)\t\(identity.executablePath)\t\(describe(classifier.classify(identity)))")
}

if arguments.first == "--all" {
    let pids = (try? proc.listPIDs()) ?? []
    for pid in pids.sorted() {
        printClassification(pid: pid)
    }
} else if let value = arguments.first, let pid = pid_t(value) {
    printClassification(pid: pid)
} else {
    fputs("usage: sanctuary-classify-live <pid>|--all\n", stderr)
    exit(2)
}
