//
//  BootDiagnostics.swift
//  MeloNX
//

import Foundation

struct BootStageRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let elapsed: TimeInterval
    let thread: String
    let stage: String
    let result: String?
}

/// Central, persistent record of the boot sequence from `startGame()` to
/// the first rendered frame - built because "Loading" could get stuck with
/// zero information about where. Every stage is printed (so it shows in
/// the on-screen LogView once LogCapture's filter stops dropping [BOOT]
/// lines) AND persisted to Documents/Diagnostics/boot-last.txt on every
/// single call, so even a UI that's stuck/unresponsive still leaves a real
/// trail on disk.
///
/// C#-side breadcrumbs (swapchain/first submit/first present, added as
/// plain Console.WriteLine/Logger calls around WindowBase.cs's render
/// loop) are not pushed into this object through a second bridge - they
/// already flow through the same stdout capture LogCapture already does
/// for everything else. `observeExternalBootLines()` just mirrors
/// `[BOOT] ...` lines seen there into this object's structured fields.
final class BootDiagnostics: ObservableObject {
    static let shared = BootDiagnostics()

    @Published private(set) var stages: [BootStageRecord] = []
    @Published private(set) var lastStage: String = "idle"
    @Published private(set) var failureStage: String?
    @Published private(set) var failureReason: String?

    @Published private(set) var environment: String?
    @Published private(set) var jitVerified: Bool?
    @Published private(set) var dualMappedJIT: Bool?
    @Published private(set) var ryujinxStarted = false
    @Published private(set) var swapchainCreated = false
    @Published private(set) var firstSubmit = false
    @Published private(set) var firstPresent = false
    @Published private(set) var firstFrame = false

    private var startedAt: Date?
    private var observeTask: Task<Void, Never>?
    private let lock = NSLock()

    private init() {
        observeExternalBootLines()
    }

    /// Resets transitory per-launch state. Never touches anything else -
    /// a fresh launch attempt should not need to re-derive its own
    /// identity, just start a clean timeline.
    func beginBoot() {
        lock.lock()
        startedAt = Date()
        lock.unlock()

        DispatchQueue.main.async {
            self.stages = []
            self.lastStage = "idle"
            self.failureStage = nil
            self.failureReason = nil
            self.environment = nil
            self.jitVerified = nil
            self.dualMappedJIT = nil
            self.ryujinxStarted = false
            self.swapchainCreated = false
            self.firstSubmit = false
            self.firstPresent = false
            self.firstFrame = false
        }
    }

    @discardableResult
    func log(_ stage: String, result: String? = nil) -> BootStageRecord {
        let elapsed: TimeInterval
        lock.lock()
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()

        let threadName = currentThreadName()
        let record = BootStageRecord(timestamp: Date(), elapsed: elapsed, thread: threadName, stage: stage, result: result)

        DispatchQueue.main.async {
            self.stages.append(record)
            self.lastStage = stage
            self.applyKnownStage(stage, result: result)
        }

        let message = "[BOOT] \(stage)" + (result.map { " = \($0)" } ?? "")
        print(message)
        persistLastStep(message)

        return record
    }

    func fail(stage: String, reason: String) {
        DispatchQueue.main.async {
            self.failureStage = stage
            self.failureReason = reason
        }
        let message = "[BOOT] \(stage) FAILED: \(reason)"
        print(message)
        persistLastStep(message)
    }

    private func currentThreadName() -> String {
        if Thread.isMainThread { return "main" }
        if let name = Thread.current.name, !name.isEmpty { return name }
        return "background"
    }

    private func applyKnownStage(_ stage: String, result: String?) {
        switch stage {
        case "environment":
            environment = result
        case "JIT verification result":
            jitVerified = (result == "true")
        case "initialize_dualmapped result", "initialize_dualmapped returned":
            dualMappedJIT = (result == "true")
        case "ryujinx.start begin":
            ryujinxStarted = true
        case "swapchain created":
            swapchainCreated = true
        case "first GPU command submitted":
            firstSubmit = true
        case "first present requested", "first present completed":
            firstPresent = true
        case "ran-first-frame", "received ran-first-frame", "emitting ran-first-frame":
            firstFrame = true
        default:
            break
        }
    }

    private func persistLastStep(_ message: String) {
        let dir = URL.documentsDirectory.appendingPathComponent("Diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("boot-last.txt")
        try? message.write(to: url, atomically: true, encoding: .utf8)
    }

    private func observeExternalBootLines() {
        observeTask = Task {
            for await chunk in LogCapture.shared.logs {
                guard chunk.contains("[BOOT]") else { continue }
                for rawLine in chunk.split(separator: "\n") {
                    guard let range = rawLine.range(of: "[BOOT] ") else { continue }
                    let rest = String(rawLine[range.upperBound...])
                    let stage: String
                    let result: String?
                    if let eq = rest.range(of: " = ") {
                        stage = String(rest[rest.startIndex..<eq.lowerBound])
                        result = String(rest[eq.upperBound...])
                    } else {
                        stage = rest
                        result = nil
                    }
                    await MainActor.run {
                        self.applyKnownStage(stage, result: result)
                    }
                }
            }
        }
    }

    func buildReport() -> String {
        var lines: [String] = ["[GAME BOOT DIAGNOSTICS]", ""]
        lines.append("environment = \(environment ?? "unknown")")
        lines.append("jitVerified = \(jitVerified.map { "\($0)" } ?? "unknown")")
        lines.append("dualMappedJIT = \(dualMappedJIT.map { "\($0)" } ?? "unknown")")
        lines.append("lastStage = \(lastStage)")
        lock.lock()
        let elapsedNow = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()
        lines.append("elapsed = \(String(format: "%.1fs", elapsedNow))")
        lines.append("ryujinxStarted = \(ryujinxStarted)")
        lines.append("swapchainCreated = \(swapchainCreated)")
        lines.append("firstSubmit = \(firstSubmit)")
        lines.append("firstPresent = \(firstPresent)")
        lines.append("firstFrame = \(firstFrame)")
        lines.append("")
        lines.append("failureStage = \(failureStage ?? "none")")
        lines.append("failureReason = \(failureReason ?? "none")")
        lines.append("")
        lines.append("STAGES:")
        for stage in stages {
            lines.append("[\(String(format: "%.2f", stage.elapsed))s][\(stage.thread)] \(stage.stage)" + (stage.result.map { " = \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    func saveReportToDisk() -> String {
        let report = buildReport()
        let dir = URL.documentsDirectory.appendingPathComponent("Diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("boot-report.txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)
        return report
    }
}
