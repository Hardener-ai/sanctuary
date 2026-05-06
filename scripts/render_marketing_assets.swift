// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let screenshots = root.appendingPathComponent("docs/demo/screenshots", isDirectory: true)
let frames = root.appendingPathComponent("docs/demo/frames", isDirectory: true)
let brand = root.appendingPathComponent("docs/assets/brand", isDirectory: true)

try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

let canvasSize = NSSize(width: 1920, height: 1080)

struct Palette {
    static let black = NSColor(calibratedRed: 0.015, green: 0.015, blue: 0.018, alpha: 1)
    static let panel = NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.086, alpha: 1)
    static let panel2 = NSColor(calibratedRed: 0.105, green: 0.108, blue: 0.118, alpha: 1)
    static let border = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let text = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let muted = NSColor(calibratedWhite: 0.68, alpha: 1)
    static let dim = NSColor(calibratedWhite: 0.42, alpha: 1)
    static let red = NSColor(calibratedRed: 1.0, green: 0.075, blue: 0.055, alpha: 1)
    static let green = NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.44, alpha: 1)
    static let yellow = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.18, alpha: 1)
}

func image(_ relative: String) -> NSImage {
    let url = brand.appendingPathComponent(relative)
    guard let image = NSImage(contentsOf: url) else {
        fatalError("Missing image: \(url.path)")
    }
    return image
}

let logoBlack = image("hardener-logo-stacked-on-black.png")
let logoWhite = image("hardener-logo-horizontal-on-white.png")
let iconBlack = image("hardener-icon-on-black.png")

func drawText(
    _ text: String,
    at point: NSPoint,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = Palette.text,
    width: CGFloat = 1200,
    alignment: NSTextAlignment = .left
) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineSpacing = size * 0.18
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    let attributed = NSAttributedString(string: text, attributes: attrs)
    let bounds = attributed.boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let height = ceil(bounds.height) + 8
    // Treat `point.y` as the visual top edge. AppKit's default coordinate
    // space is bottom-left, and NSString draws text from the top of its rect.
    let rect = NSRect(x: point.x, y: point.y - height, width: width, height: height)
    attributed.draw(in: rect)
}

func fillRounded(_ rect: NSRect, radius: CGFloat = 24, color: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func drawPill(_ text: String, rect: NSRect, color: NSColor, textColor: NSColor = Palette.text) {
    fillRounded(rect, radius: rect.height / 2, color: color)
    drawText(text, at: NSPoint(x: rect.minX, y: rect.midY + 12), size: 18, weight: .semibold, color: textColor, width: rect.width, alignment: .center)
}

func drawCard(_ rect: NSRect) {
    fillRounded(rect, radius: 26, color: Palette.panel, stroke: Palette.border)
}

func drawMacWindow(_ rect: NSRect, title: String) {
    drawCard(rect)
    fillRounded(NSRect(x: rect.minX, y: rect.maxY - 58, width: rect.width, height: 58), radius: 26, color: Palette.panel2)
    for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 28 + CGFloat(index) * 28, y: rect.maxY - 36, width: 12, height: 12)).fill()
    }
    drawText(title, at: NSPoint(x: rect.minX, y: rect.maxY - 40), size: 16, weight: .medium, color: Palette.muted, width: rect.width, alignment: .center)
}

func drawTerminalLine(_ text: String, x: CGFloat, y: CGFloat, color: NSColor = Palette.text) {
    let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

func drawScreenshot(name: String, draw: () -> Void) {
    let canvas = NSImage(size: canvasSize)
    canvas.lockFocus()
    Palette.black.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.01, blue: 0.01, alpha: 1),
        Palette.black
    ])
    gradient?.draw(in: NSRect(origin: .zero, size: canvasSize), angle: 290)
    draw()
    canvas.unlockFocus()

    guard
        let tiff = canvas.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not encode \(name)")
    }
    try! png.write(to: screenshots.appendingPathComponent(name))
}

func copyScreenshotToFrame(_ screenshotName: String, frameName: String) {
    let source = screenshots.appendingPathComponent(screenshotName)
    let destination = frames.appendingPathComponent(frameName)
    try? FileManager.default.removeItem(at: destination)
    try! FileManager.default.copyItem(at: source, to: destination)
}

drawScreenshot(name: "01-hero.png") {
    logoBlack.draw(in: NSRect(x: 515, y: 580, width: 890, height: 501), from: .zero, operation: .sourceOver, fraction: 1)
    drawPill("v0.1 pre-launch · AGPL v3 · macOS", rect: NSRect(x: 720, y: 520, width: 480, height: 44), color: NSColor(calibratedWhite: 1, alpha: 0.10))
    drawText("Stop AI agents from reaching wallets, SSH keys, and secrets.", at: NSPoint(x: 300, y: 390), size: 52, weight: .bold, width: 1320, alignment: .center)
    drawText("Sanctuary by Hardener watches protected folders, wallet extensions, and browser CDP sessions. It detects every attempt and blocks the browser-wallet attack path in real time.", at: NSPoint(x: 480, y: 230), size: 24, color: Palette.muted, width: 960, alignment: .center)
}

drawScreenshot(name: "02-menu-bar-protections.png") {
    drawText("Menu bar protection, not another dashboard.", at: NSPoint(x: 120, y: 890), size: 48, weight: .bold, width: 900)
    drawText("A quiet native macOS surface shows what is protected, which agents are running, and what happened in the last hour.", at: NSPoint(x: 120, y: 735), size: 24, color: Palette.muted, width: 780)

    drawMacWindow(NSRect(x: 1040, y: 140, width: 500, height: 760), title: "Sanctuary")
    drawText("Sanctuary protection", at: NSPoint(x: 1090, y: 820), size: 20, weight: .semibold, width: 280)
    drawPill("ON", rect: NSRect(x: 1420, y: 812, width: 70, height: 34), color: Palette.green, textColor: Palette.black)
    drawText("All protections active", at: NSPoint(x: 1120, y: 760), size: 18, weight: .medium, width: 300)
    Palette.green.setFill()
    NSBezierPath(ovalIn: NSRect(x: 1090, y: 765, width: 12, height: 12)).fill()

    let rows = [
        ("FOLDERS", "~/.ssh\n~/.aws\n~/.gnupg"),
        ("WALLETS & PASSWORDS", "MetaMask · Brave Default\nPhantom · Chrome Profile 1\n1Password · Brave Default"),
        ("RUNNING AGENTS (3)", "Codex CLI · Coding agent\nHermes Agent · Background service\nOpenClaw · Background service")
    ]
    var y: CGFloat = 690
    for (heading, body) in rows {
        drawText(heading, at: NSPoint(x: 1090, y: y), size: 13, weight: .bold, color: Palette.dim, width: 360)
        drawText(body, at: NSPoint(x: 1090, y: y - 90), size: 18, color: Palette.text, width: 360)
        y -= 180
    }

    drawCard(NSRect(x: 120, y: 220, width: 760, height: 430))
    drawText("Protected surfaces", at: NSPoint(x: 170, y: 570), size: 28, weight: .semibold, width: 500)
    drawText("• Folders you choose\n• Browser wallet extension storage\n• Password manager extension storage\n• Browser CDP sessions", at: NSPoint(x: 170, y: 420), size: 26, color: Palette.text, width: 560)
}

drawScreenshot(name: "03-cdp-guard-block.png") {
    drawText("The load-bearing v0.1 block: CDP Guard.", at: NSPoint(x: 120, y: 910), size: 48, weight: .bold, width: 1000)
    drawText("A classified agent tries to attach to a protected browser wallet session. Sanctuary cuts the loopback connection before the wallet can be driven.", at: NSPoint(x: 120, y: 835), size: 24, color: Palette.muted, width: 1100)

    drawMacWindow(NSRect(x: 110, y: 160, width: 820, height: 590), title: "Agent terminal")
    let terminalLines = [
        "$ codex run portfolio-tracker",
        "Connecting to wallet session...",
        "GET http://127.0.0.1:19222/json/version",
        "ERROR: connection refused",
        "Retrying...",
        "ERROR: connection refused",
        "Sanctuary: CDP attach blocked"
    ]
    var ty: CGFloat = 650
    for (index, line) in terminalLines.enumerated() {
        drawTerminalLine(line, x: 160, y: ty, color: index >= 3 ? Palette.red : Palette.text)
        ty -= 54
    }

    drawMacWindow(NSRect(x: 1000, y: 160, width: 800, height: 590), title: "Protected browser profile")
    drawText("MetaMask", at: NSPoint(x: 1060, y: 630), size: 38, weight: .bold, width: 400)
    drawText("Balance", at: NSPoint(x: 1060, y: 565), size: 20, color: Palette.muted, width: 300)
    drawText("0.05 testnet ETH", at: NSPoint(x: 1060, y: 505), size: 42, weight: .bold, color: Palette.green, width: 390)
    drawPill("untouched", rect: NSRect(x: 1060, y: 395, width: 160, height: 42), color: NSColor(calibratedRed: 0.06, green: 0.35, blue: 0.14, alpha: 1))
    iconBlack.draw(in: NSRect(x: 1490, y: 405, width: 180, height: 180), from: .zero, operation: .sourceOver, fraction: 1)
}

drawScreenshot(name: "04-audit-feed.png") {
    drawText("Every attempt becomes evidence.", at: NSPoint(x: 120, y: 910), size: 48, weight: .bold, width: 900)
    drawText("Sanctuary records detection and tamper events in a signed JSONL audit log with SHA-256 hash-chain continuity.", at: NSPoint(x: 120, y: 835), size: 24, color: Palette.muted, width: 1120)

    drawMacWindow(NSRect(x: 140, y: 150, width: 760, height: 610), title: "Audit activity")
    let activity = [
        ("just now", "Codex tried to attach to Brave", "Blocked"),
        ("2 minutes ago", "Hermes accessed ~/.ssh", "Detected · definite"),
        ("5 minutes ago", "OpenClaw tried to read MetaMask", "Detected · definite"),
        ("8 minutes ago", "pf rules re-installed after tampering", "Tamper detected")
    ]
    var ay: CGFloat = 650
    for item in activity {
        Palette.red.setFill()
        NSBezierPath(ovalIn: NSRect(x: 190, y: ay + 6, width: 12, height: 12)).fill()
        drawText(item.0, at: NSPoint(x: 220, y: ay), size: 16, color: Palette.muted, width: 250)
        drawText(item.1, at: NSPoint(x: 220, y: ay - 36), size: 24, weight: .semibold, width: 560)
        drawText(item.2, at: NSPoint(x: 220, y: ay - 70), size: 17, color: item.2 == "Blocked" ? Palette.red : Palette.muted, width: 560)
        ay -= 120
    }

    drawMacWindow(NSRect(x: 980, y: 150, width: 780, height: 610), title: "sanctuary log verify")
    let logLines = [
        "Audit log valid.",
        "376 entries verified.",
        "Hash chain intact.",
        "",
        "Tamper test:",
        "VERIFICATION FAILED at entry 145",
        "Reason: hash chain broken"
    ]
    var ly: CGFloat = 650
    for (index, line) in logLines.enumerated() {
        drawTerminalLine(line, x: 1030, y: ly, color: index >= 5 ? Palette.yellow : Palette.text)
        ly -= 52
    }
}

drawScreenshot(name: "05-e2e-proof.png") {
    drawText("Reproducible proof, not vibes.", at: NSPoint(x: 120, y: 910), size: 48, weight: .bold, width: 900)
    drawText("The e2e suite runs attack scenarios against a live machine and emits evidence artifacts.", at: NSPoint(x: 120, y: 835), size: 24, color: Palette.muted, width: 1000)

    let metrics = [
        ("376", "tests passing"),
        ("8", "e2e scenarios"),
        ("44", "known agents"),
        ("35+", "wallets & password managers")
    ]
    var mx: CGFloat = 120
    for metric in metrics {
        drawCard(NSRect(x: mx, y: 600, width: 380, height: 180))
        drawText(metric.0, at: NSPoint(x: mx, y: 700), size: 58, weight: .bold, color: Palette.red, width: 380, alignment: .center)
        drawText(metric.1, at: NSPoint(x: mx, y: 650), size: 22, color: Palette.muted, width: 380, alignment: .center)
        mx += 430
    }

    drawMacWindow(NSRect(x: 180, y: 130, width: 1560, height: 380), title: "./e2e/run-all.sh")
    let lines = [
        "scenario-classifier-hermes-openclaw.sh        PASS",
        "scenario-fs-detection-ssh.sh                 PASS",
        "scenario-extension-storage-metamask.sh       PASS",
        "scenario-user-tagged-agent.sh                PASS",
        "scenario-tamper-evident-audit.sh             PASS",
        "scenario-tamper-peer-disconnect.sh           PASS",
        "scenario-cdp-guard-blocks.sh                 SKIP unless E2E_PF=1",
        "scenario-tamper-pf-flush.sh                  SKIP unless E2E_PF=1"
    ]
    var ey: CGFloat = 430
    for line in lines {
        drawTerminalLine(line, x: 230, y: ey, color: line.contains("PASS") ? Palette.green : Palette.yellow)
        ey -= 34
    }
}

drawScreenshot(name: "06-roadmap.png") {
    drawText("Built native now. Shared core later.", at: NSPoint(x: 120, y: 910), size: 48, weight: .bold, width: 1000)
    drawText("The v0.1 launch path stays Swift-native on macOS. Rust becomes the shared policy/classifier core once multiple platforms prove the common shape.", at: NSPoint(x: 120, y: 835), size: 24, color: Palette.muted, width: 1140)

    let stages = [
        ("v0.1", "macOS Swift", "Launch with CDP block, detection, audit log, menu bar"),
        ("v0.2", "Endpoint Security", "Invisibility, human approval, capability scoping"),
        ("v1.0", "Shared Rust core", "Classifier, policy engine, audit verifier"),
        ("v1.0+", "Windows + Linux", "Native collectors, shared decisions")
    ]
    var x: CGFloat = 130
    for stage in stages {
        drawCard(NSRect(x: x, y: 300, width: 390, height: 360))
        drawText(stage.0, at: NSPoint(x: x + 40, y: 560), size: 44, weight: .bold, color: Palette.red, width: 300)
        drawText(stage.1, at: NSPoint(x: x + 40, y: 500), size: 26, weight: .semibold, width: 300)
        drawText(stage.2, at: NSPoint(x: x + 40, y: 385), size: 20, color: Palette.muted, width: 310)
        x += 440
    }
}

let frameMap = [
    ("01-hero.png", "frame-01.png"),
    ("02-menu-bar-protections.png", "frame-02.png"),
    ("03-cdp-guard-block.png", "frame-03.png"),
    ("04-audit-feed.png", "frame-04.png"),
    ("05-e2e-proof.png", "frame-05.png"),
    ("06-roadmap.png", "frame-06.png")
]
for item in frameMap {
    copyScreenshotToFrame(item.0, frameName: item.1)
}

let concat = """
file '../frames/frame-01.png'
duration 3.0
file '../frames/frame-02.png'
duration 3.5
file '../frames/frame-03.png'
duration 4.0
file '../frames/frame-04.png'
duration 3.5
file '../frames/frame-05.png'
duration 3.5
file '../frames/frame-06.png'
duration 3.5
file '../frames/frame-06.png'
"""
try concat.write(to: root.appendingPathComponent("docs/demo/video/demo-concat.txt"), atomically: true, encoding: .utf8)

print("Rendered launch assets to docs/demo/screenshots")
