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
/// C#-side breadcrumbs reach this object two ways: `observeExternalBootLines()`
/// mirrors `[BOOT] ...` text already flowing through LogCapture's stdout
/// capture, and `registerManagedBootEventChannel()` listens on a dedicated,
/// deterministic bridge (Program.cs's ReportBootEvent/ReportBootFailure) for
/// the critical path - added because whether stdout reaches this process
/// reliably at all was exactly what needed verifying, not assuming.
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

    // Watchdog-panel fields: whether the managed (.NET) side and the GPU
    // render thread have shown ANY sign of life, and the last named stage
    // each reported - so a timeout can say *where* it's stuck instead of
    // just "nothing happened".
    @Published private(set) var managedThreadAlive = false
    @Published private(set) var renderThreadAlive = false
    @Published private(set) var lastManagedStage: String?
    @Published private(set) var lastRendererStage: String?
    @Published private(set) var lastVulkanResult: String?
    @Published private(set) var metalViewAlive = false
    @Published private(set) var surfaceCreated = false

    private var startedAt: Date?
    private var observeTask: Task<Void, Never>?
    private let lock = NSLock()

    private init() {
        observeExternalBootLines()
        registerManagedBootEventChannel()
    }

    /// Deterministic C#->Swift bridge, requested explicitly instead of
    /// relying only on stdout/LogCapture (unverified until now whether it
    /// even reaches this process reliably). Reuses the existing, already
    /// proven RegisterCallbackWithData mechanism under one new identifier,
    /// "boot-event", fed by Program.cs's ReportBootEvent/ReportBootFailure.
    /// Payload is plain UTF-8: "name", "name|value", or "FAIL|stage|reason".
    private func registerManagedBootEventChannel() {
        RegisterCallbackWithData("boot-event") { [weak self] data in
            guard let self, let data, let payload = String(data: data, encoding: .utf8) else { return }
            switch BootEventPayloadParser.parse(payload) {
            case .stage(let name, let value):
                self.log(name, result: value)
            case .failure(let stage, let reason):
                self.fail(stage: stage, reason: reason)
            }
        }
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
            self.managedThreadAlive = false
            self.renderThreadAlive = false
            self.lastManagedStage = nil
            self.lastRendererStage = nil
            self.lastVulkanResult = nil
            self.metalViewAlive = false
            self.surfaceCreated = false
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
        case "MetalView.createView begin", "MetalView.createView end":
            metalViewAlive = true
        default:
            break
        }

        // Broader, substring-based classification for the watchdog panel -
        // deliberately not an exhaustive exact-match list, since the real
        // managed/renderer stage names are numerous and this only needs to
        // answer "is each side alive, and what was its last named stage".
        if stageLooksManaged(stage) {
            managedThreadAlive = true
            lastManagedStage = stage
        }

        if stageLooksRenderer(stage) {
            lastRendererStage = stage
        }

        if stage.localizedCaseInsensitiveContains("vulkan"), let result {
            lastVulkanResult = result
        }

        if stage == "GPU thread started" || stage.contains("render loop entered") {
            renderThreadAlive = true
        }

        if stage.contains("surface creation success") {
            surfaceCreated = true
        }

        if stage.contains("swapchain creation success") || stage == "swapchain created" {
            swapchainCreated = true
        }

        if stage.contains("first GPU command submitted") || stage.contains("first submit") {
            firstSubmit = true
        }

        if stage.contains("first present") {
            firstPresent = true
        }

        if stage == "ran-first-frame" || stage.contains("ran-first-frame") || stage.contains("first frame") {
            firstFrame = true
        }
    }

    private func stageLooksManaged(_ stage: String) -> Bool {
        let markers = ["managed", "Program.Main", "args received", "app data", "configuration", "game load", "BOOT-TEST"]
        return markers.contains { stage.localizedCaseInsensitiveContains($0) }
    }

    private func stageLooksRenderer(_ stage: String) -> Bool {
        let markers = ["renderer", "vulkan", "physical device", "logical device", "surface", "swapchain", "render loop", "command buffer"]
        return markers.contains { stage.localizedCaseInsensitiveContains($0) }
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
        lines.append("managedThreadAlive = \(managedThreadAlive)")
        lines.append("renderThreadAlive = \(renderThreadAlive)")
        lines.append("lastManagedStage = \(lastManagedStage ?? "none")")
        lines.append("lastRendererStage = \(lastRendererStage ?? "none")")
        lines.append("lastVulkanResult = \(lastVulkanResult ?? "none")")
        lines.append("metalViewAlive = \(metalViewAlive)")
        lines.append("surfaceCreated = \(surfaceCreated)")
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

/// Pure parsing for the "boot-event" channel's payload, kept separate from
/// BootDiagnostics itself so the actual decoding logic is unit-testable
/// without needing the real native RegisterCallbackWithData bridge (which
/// has no C# runtime to drive it in a test host).
enum BootEventPayloadParser {
    enum ParsedEvent: Equatable {
        case stage(name: String, value: String?)
        case failure(stage: String, reason: String)
    }

    static func parse(_ payload: String) -> ParsedEvent {
        if payload.hasPrefix("FAIL|") {
            let rest = payload.dropFirst(5)
            guard let separator = rest.range(of: "|") else {
                return .failure(stage: "unknown", reason: String(rest))
            }
            let stage = String(rest[rest.startIndex..<separator.lowerBound])
            let reason = String(rest[separator.upperBound...])
            return .failure(stage: stage, reason: reason)
        }

        if let separator = payload.range(of: "|") {
            let name = String(payload[payload.startIndex..<separator.lowerBound])
            let value = String(payload[separator.upperBound...])
            return .stage(name: name, value: value)
        }

        return .stage(name: payload, value: nil)
    }
}
