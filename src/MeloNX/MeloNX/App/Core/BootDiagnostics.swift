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

    // Swapchain -> acquire -> command buffer -> submit -> present trace
    // (diagnóstico real #3): each flag below is set ONLY from a real,
    // named Vulkan-level result event - never from "we entered the
    // method" alone. See BootDiagnostics' doc comment update and
    // PERFORMANCE_FORK.md for the exact contract each event name has
    // with Ryujinx.Graphics.Vulkan/Window.cs and CommandBufferPool.cs.
    @Published private(set) var swapchainImageCount: Int?
    @Published private(set) var swapchainHandle: String?
    @Published private(set) var acquireAttempted = false
    @Published private(set) var acquireAttemptCount = 0
    @Published private(set) var firstAcquireSucceeded = false
    @Published private(set) var lastAcquireResult: String?
    @Published private(set) var commandBufferStarted = false
    @Published private(set) var commandBufferRecorded = false
    @Published private(set) var lastSubmitResult: String?
    @Published private(set) var lastPresentResult: String?
    @Published private(set) var renderLoopEntered = false
    @Published private(set) var renderLoopIterations = 0
    @Published private(set) var lastRenderLoopStage: String?
    @Published private(set) var lastRenderActivityTimestamp: Date?

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
            self.swapchainImageCount = nil
            self.swapchainHandle = nil
            self.acquireAttempted = false
            self.acquireAttemptCount = 0
            self.firstAcquireSucceeded = false
            self.lastAcquireResult = nil
            self.commandBufferStarted = false
            self.commandBufferRecorded = false
            self.lastSubmitResult = nil
            self.lastPresentResult = nil
            self.renderLoopEntered = false
            self.renderLoopIterations = 0
            self.lastRenderLoopStage = nil
            self.lastRenderActivityTimestamp = nil
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

    /// Stage names whose `result` is itself a VkResult string - the only
    /// reliable way to populate `lastVulkanResult`. A previous version of
    /// this matched on `stage.contains("vulkan")`, which never actually
    /// matched any real stage name (they're all "vkCreateInstance",
    /// "vkCreateSwapchainKHR", "acquire result", etc - none contain the
    /// literal word "vulkan") - that bug is why `lastVulkanResult` always
    /// read "none" even once Vulkan calls were clearly succeeding.
    /// "vkGetPhysicalDeviceSurfaceSupportKHR" is deliberately excluded here:
    /// its value is "true (queue family N, queueCount M)" on success, not a
    /// VkResult symbol, so including it would make lastVulkanResult show a
    /// non-VkResult string instead of the thing its name promises.
    private static let vulkanResultStageNames: Set<String> = [
        "vkCreateInstance", "vkEnumeratePhysicalDevices", "vkCreateDevice",
        "vkCreateMetalSurfaceEXT", "vkCreateSwapchainKHR",
        "acquire result", "queueSubmit result", "queuePresent result",
    ]

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
        case "swapchain creation success":
            swapchainCreated = true
            if let result {
                swapchainHandle = Self.extractField(result, "handle")
                if let s = Self.extractField(result, "imageCount"), let n = Int(s) {
                    swapchainImageCount = n
                }
            }
        case "acquire begin":
            acquireAttempted = true
        case "acquire result":
            acquireAttemptCount += 1
            lastAcquireResult = result
            if result == "Success" {
                firstAcquireSucceeded = true
            }
        case "command buffer begin":
            commandBufferStarted = true
        case "command buffer recorded":
            commandBufferRecorded = true
        case "queueSubmit result":
            lastSubmitResult = result
            // firstSubmit means a REAL vkQueueSubmit returned Success - not
            // "we entered the method that calls it", which is what the
            // previous round's "first GPU command submitted" breadcrumb
            // actually measured (Device.WaitFifo() returning true, a
            // managed-level FIFO concept, not a Vulkan API result).
            if result == "Success" {
                firstSubmit = true
            }
        case "queuePresent result":
            lastPresentResult = result
            // firstPresent means a REAL vkQueuePresentKHR returned Success
            // or SuboptimalKHR (SuboptimalKHR still presented the frame -
            // the swapchain is just scheduled for recreation on next use).
            if result == "Success" || result == "SuboptimalKhr" {
                firstPresent = true
            }
        case "render loop heartbeat":
            if let result, let n = Int(result) {
                renderLoopIterations = n
            }
        case "ran-first-frame":
            // The engine's own "a frame was handed to SwapBuffers" signal.
            // Trust it as firstFrame ONLY if we already saw a real
            // successful present - otherwise this is a real anomaly (the
            // engine believes it presented a frame but our instrumentation
            // of the one and only present call site never observed a
            // matching success), worth surfacing rather than silently
            // accepting.
            if firstPresent {
                firstFrame = true
            } else {
                log("anomaly: ran-first-frame fired with no observed successful queuePresent", result: "lastPresentResult=\(lastPresentResult ?? "none")")
            }
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

        if Self.vulkanResultStageNames.contains(stage), let result {
            lastVulkanResult = result
        }

        if stage == "GPU thread started" || stage.contains("render loop entered") {
            renderThreadAlive = true
            renderLoopEntered = true
        }

        if stage.contains("surface creation success") {
            surfaceCreated = true
        }

        // Render-loop stall detection: ANY of these per-frame Vulkan-level
        // events (not just the broad "renderer" substring markers above,
        // which miss e.g. "queueSubmit result") counts as real forward
        // progress with a fresh timestamp - this is what
        // secondsSinceLastRenderProgress is computed from.
        let renderProgressStages: Set<String> = [
            "render loop entered", "render loop heartbeat", "acquire begin", "acquire result",
            "command buffer begin", "command buffer recorded", "command buffer end",
            "queueSubmit begin", "queueSubmit result", "queuePresent begin", "queuePresent result",
            "first present requested", "first present completed", "ran-first-frame",
            // Diagnóstico real #4 (GPU renderer initialized -> primer acquire):
            // the actual game-loop closure runs on a SEPARATE thread
            // ("GPU.MainThread") from the one Render() itself runs on
            // ("GUI.RenderLoop") - these milestones are what prove that
            // thread, and the blocking calls before its while-loop, are
            // making real progress rather than silently stuck.
            "GPU.MainThread lambda entered",
            "before Device.Gpu.SetGpuThread", "after Device.Gpu.SetGpuThread",
            "before Device.Gpu.InitializeShaderCache", "after Device.Gpu.InitializeShaderCache",
            "SetGpuThread begin", "SetGpuThread: before GetCapabilities", "SetGpuThread: after GetCapabilities",
            "InitializeShaderCache: before HostInitalized wait", "InitializeShaderCache: after HostInitalized wait",
            "InitializeShaderCache: end",
            "about to evaluate loop condition", "render loop iteration begin", "render loop returning early",
            "render loop ended: _isActive became false",
            "before pauseEvent wait", "after pauseEvent wait", "before WaitFifo", "after WaitFifo",
            "ThreadedRenderer.RunLoop begin", "ThreadedRenderer.RunLoop: before gpuThread.Start",
            "ThreadedRenderer.RunLoop: after gpuThread.Start", "ThreadedRenderer.RunLoop: before RenderLoop consumer",
            "ThreadedRenderer.RunLoop: after RenderLoop consumer returned",
            "ThreadedRenderer.InvokeCommand begin", "ThreadedRenderer.InvokeCommand: before wait",
            "ThreadedRenderer.InvokeCommand: after wait",
        ]
        if renderProgressStages.contains(stage) || stageLooksRenderer(stage) {
            lastRenderLoopStage = stage
            lastRenderActivityTimestamp = Date()
        }
    }

    /// Pulls `key=value` out of a comma-separated "k1=v1,k2=v2" result
    /// string (the format BootEventBridge-side events use for multi-field
    /// payloads, e.g. "handle=123,extent=1320x743,imageCount=3").
    private static func extractField(_ payload: String, _ key: String) -> String? {
        for part in payload.split(separator: ",") {
            if let eq = part.range(of: "=") {
                let k = String(part[part.startIndex..<eq.lowerBound])
                if k == key {
                    return String(part[eq.upperBound...])
                }
            }
        }
        return nil
    }

    /// Seconds since the render loop last showed any real forward progress
    /// (any per-frame Vulkan-level event, see `applyKnownStage`) - nil if
    /// the render loop never even entered. Computed on read rather than
    /// stored, so callers always get a fresh value.
    func secondsSinceLastRenderProgress() -> Double? {
        guard let lastRenderActivityTimestamp else { return nil }
        return Date().timeIntervalSince(lastRenderActivityTimestamp)
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
        lines.append("swapchainImageCount = \(swapchainImageCount.map { "\($0)" } ?? "unknown")")
        lines.append("acquireAttempted = \(acquireAttempted)")
        lines.append("acquireAttemptCount = \(acquireAttemptCount)")
        lines.append("firstAcquireSucceeded = \(firstAcquireSucceeded)")
        lines.append("lastAcquireResult = \(lastAcquireResult ?? "none")")
        lines.append("commandBufferStarted = \(commandBufferStarted)")
        lines.append("commandBufferRecorded = \(commandBufferRecorded)")
        lines.append("lastSubmitResult = \(lastSubmitResult ?? "none")")
        lines.append("lastPresentResult = \(lastPresentResult ?? "none")")
        lines.append("renderLoopEntered = \(renderLoopEntered)")
        lines.append("renderLoopIterations = \(renderLoopIterations)")
        lines.append("lastRenderLoopStage = \(lastRenderLoopStage ?? "none")")
        lines.append("secondsSinceLastRenderProgress = \(secondsSinceLastRenderProgress().map { String(format: "%.1fs", $0) } ?? "n/a")")
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
