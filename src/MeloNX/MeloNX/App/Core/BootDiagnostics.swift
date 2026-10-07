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

    // Diagnóstico real #5: guest CPU -> Horizon -> NvServices -> GPU FIFO
    // producer -> ThreadedRenderer consumer. swapchain/acquire/submit are
    // already confirmed working and the render loop is alive and iterating
    // (WaitFifo just keeps returning false) - this section exists to answer
    // "why does the guest never produce any GPU FIFO work", not to re-trace
    // anything on the renderer/Vulkan side.
    @Published private(set) var guestMainThreadCreated = false
    @Published private(set) var guestMainThreadStarted = false
    @Published private(set) var guestMainThreadAlive = false
    @Published private(set) var guestThreadCount = 0
    @Published private(set) var guestExecutionHeartbeats = 0
    @Published private(set) var translatedFunctionsCreated = 0
    @Published private(set) var translatedFunctionsExecuted = 0
    @Published private(set) var lastGuestStage: String?

    @Published private(set) var gpuContextCreated = false
    @Published private(set) var gpuChannelsCreated = 0
    @Published private(set) var gpfifoSubmissions = 0
    @Published private(set) var fifoCommandsQueued = 0
    @Published private(set) var fifoCommandsConsumed = 0
    @Published private(set) var fifoWaitCalls = 0
    @Published private(set) var fifoWaitTrue = 0
    @Published private(set) var fifoWaitFalse = 0
    @Published private(set) var lastGpuProducerStage: String?
    @Published private(set) var lastNvStage: String?
    @Published private(set) var lastTranslatorStage: String?

    // Thread-snapshot panel (PASO 7): these three are "has this producer
    // shown ANY sign of life", same honest semantics as managedThreadAlive/
    // renderThreadAlive above - NOT a live OS thread-liveness poll.
    @Published private(set) var gpuThreadAlive = false
    @Published private(set) var fifoProducerAlive = false

    // Diagnóstico real #6: translatedFunctionsCreated/translatedFunctionsExecuted
    // (declared above, in the GUEST block) were only ever fed by
    // ARMeilleure.Translation.Translator's events - but that class is NOT
    // the active CPU backend for this build. ArmProcessContextFactory picks
    // LightningJitEngine whenever running on an arm64 host with
    // MemoryManagerMode.HostMapped/HostMappedUnsafe (the default here, no
    // override found anywhere in the Swift app), which is exactly this
    // app's real configuration. Both fields are now ALSO fed from
    // Ryujinx.Cpu.LightningJit.Translator's real events below (via a
    // `max(current, newValue)` merge - whichever backend actually runs
    // drives the number, nothing is overwritten backwards) - fixing the
    // exact "no asumas que son correctas" concern this round raised.
    @Published private(set) var contextExecuteEntered = false
    @Published private(set) var contextExecuteReturned = false
    @Published private(set) var translatorExecuteEntered = false
    @Published private(set) var translatorLookupAttempts = 0
    @Published private(set) var translationAttempts = 0
    @Published private(set) var nopFallbackCount = 0
    @Published private(set) var jitCodeAllocations = 0
    @Published private(set) var jitBytesGenerated = 0
    @Published private(set) var firstGuestPc: String?
    @Published private(set) var lastGuestPc: String?
    @Published private(set) var lastTranslatorAddress: String?
    @Published private(set) var jitRwAddress: String?
    @Published private(set) var jitRxAddress: String?
    @Published private(set) var hostFunctionCallAttempted = false
    @Published private(set) var hostFunctionCallReturned = false

    private var startedAt: Date?
    private var observeTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var snapshot10sTaken = false
    private var snapshot20sTaken = false
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
            self.guestMainThreadCreated = false
            self.guestMainThreadStarted = false
            self.guestMainThreadAlive = false
            self.guestThreadCount = 0
            self.guestExecutionHeartbeats = 0
            self.translatedFunctionsCreated = 0
            self.translatedFunctionsExecuted = 0
            self.lastGuestStage = nil
            self.gpuContextCreated = false
            self.gpuChannelsCreated = 0
            self.gpfifoSubmissions = 0
            self.fifoCommandsQueued = 0
            self.fifoCommandsConsumed = 0
            self.fifoWaitCalls = 0
            self.fifoWaitTrue = 0
            self.fifoWaitFalse = 0
            self.lastGpuProducerStage = nil
            self.lastNvStage = nil
            self.lastTranslatorStage = nil
            self.gpuThreadAlive = false
            self.fifoProducerAlive = false
            self.contextExecuteEntered = false
            self.contextExecuteReturned = false
            self.translatorExecuteEntered = false
            self.translatorLookupAttempts = 0
            self.translationAttempts = 0
            self.nopFallbackCount = 0
            self.jitCodeAllocations = 0
            self.jitBytesGenerated = 0
            self.firstGuestPc = nil
            self.lastGuestPc = nil
            self.lastTranslatorAddress = nil
            self.jitRwAddress = nil
            self.jitRxAddress = nil
            self.hostFunctionCallAttempted = false
            self.hostFunctionCallReturned = false
            self.snapshot10sTaken = false
            self.snapshot20sTaken = false
        }

        scheduleThreadSnapshots()
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

    /// PASO 7: a logical snapshot of which producers/consumers have shown
    /// any sign of life and their last known stage, taken at fixed points
    /// in the boot timeline (~10s and ~20s) so the next device trace shows
    /// the exact progression over time, not just the final state when the
    /// watchdog gives up. Cancelled/restarted by every beginBoot().
    private func scheduleThreadSnapshots() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.captureSnapshot(label: "10s") }

            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.captureSnapshot(label: "20s") }
        }
    }

    private func captureSnapshot(label: String) {
        if label == "10s" {
            if snapshot10sTaken { return }
            snapshot10sTaken = true
        } else if label == "20s" {
            if snapshot20sTaken { return }
            snapshot20sTaken = true
        }

        let summary = "managedThreadAlive=\(managedThreadAlive),renderThreadAlive=\(renderThreadAlive)," +
            "guestMainThreadAlive=\(guestMainThreadAlive),gpuThreadAlive=\(gpuThreadAlive),fifoProducerAlive=\(fifoProducerAlive)," +
            "lastGuestStage=\(lastGuestStage ?? "none"),lastGpuProducerStage=\(lastGpuProducerStage ?? "none")," +
            "lastNvStage=\(lastNvStage ?? "none"),lastTranslatorStage=\(lastTranslatorStage ?? "none")," +
            "contextExecuteEntered=\(contextExecuteEntered),translatorExecuteEntered=\(translatorExecuteEntered)," +
            "translatorLookupAttempts=\(translatorLookupAttempts),translationAttempts=\(translationAttempts)," +
            "translatedFunctionsCreated=\(translatedFunctionsCreated),nopFallbackCount=\(nopFallbackCount)"

        log("boot snapshot @\(label)", result: summary)
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

    /// Diagnóstico real #6: the watchdog used to always say "timeout
    /// waiting for swapchain/first frame" regardless of how far the boot
    /// actually got - including when swapchainCreated was already true,
    /// which no longer describes the real blockage at all. This walks the
    /// pipeline (JIT -> Vulkan/swapchain -> guest CPU/translator -> GPU-FIFO
    /// producer -> renderer acquire/submit/present) and returns the
    /// stage/reason for whichever point real evidence shows execution
    /// actually stopped at - never a guess, only state already observed.
    func classifyWatchdogFailure() -> (stage: String, reason: String) {
        if jitVerified != true || dualMappedJIT != true {
            return (
                "JIT",
                "timeout before JIT verification completed; jitVerified=\(jitVerified.map { "\($0)" } ?? "unknown"), dualMappedJIT=\(dualMappedJIT.map { "\($0)" } ?? "unknown")"
            )
        }

        if !swapchainCreated {
            return (
                "renderer / swapchain",
                "timeout waiting for swapchain/first frame; lastRendererStage=\(lastRendererStage ?? "none"), lastVulkanResult=\(lastVulkanResult ?? "none")"
            )
        }

        if !guestMainThreadAlive {
            return (
                "guest CPU startup",
                "swapchain created but the guest main thread never reached Owner.Context.Execute; guestMainThreadCreated=\(guestMainThreadCreated), guestMainThreadStarted=\(guestMainThreadStarted), lastGuestStage=\(lastGuestStage ?? "none")"
            )
        }

        if translatedFunctionsCreated == 0 && gpfifoSubmissions == 0 {
            return (
                "guest CPU / translator startup",
                "guest execution entered Context.Execute but no translated function was created or executed; translatorExecuteEntered=\(translatorExecuteEntered), translatorLookupAttempts=\(translatorLookupAttempts), translationAttempts=\(translationAttempts), nopFallbackCount=\(nopFallbackCount), lastTranslatorStage=\(lastTranslatorStage ?? "none")"
            )
        }

        if gpfifoSubmissions == 0 {
            return (
                "guest CPU / GPU producer",
                "guest code is translating and executing (translatedFunctionsCreated=\(translatedFunctionsCreated)) but never submitted any GPU FIFO work; gpuChannelsCreated=\(gpuChannelsCreated), lastNvStage=\(lastNvStage ?? "none")"
            )
        }

        if !acquireAttempted {
            return (
                "renderer / acquire",
                "GPU work was submitted (gpfifoSubmissions=\(gpfifoSubmissions)) but the renderer never attempted vkAcquireNextImageKHR; fifoCommandsQueued=\(fifoCommandsQueued), fifoCommandsConsumed=\(fifoCommandsConsumed)"
            )
        }

        if !firstAcquireSucceeded {
            return (
                "renderer / acquire",
                "acquire was attempted but never succeeded; acquireAttemptCount=\(acquireAttemptCount), lastAcquireResult=\(lastAcquireResult ?? "none")"
            )
        }

        if !firstSubmit {
            return (
                "renderer / submit",
                "acquire succeeded but vkQueueSubmit never returned Success; lastSubmitResult=\(lastSubmitResult ?? "none")"
            )
        }

        if !firstPresent {
            return (
                "renderer / present",
                "submit succeeded but vkQueuePresentKHR never returned Success/SuboptimalKHR; lastPresentResult=\(lastPresentResult ?? "none")"
            )
        }

        let progress = secondsSinceLastRenderProgress().map { String(format: "%.1fs", $0) } ?? "n/a"
        return (
            "renderer / first frame",
            "present succeeded but ran-first-frame never fired or was never corroborated; secondsSinceLastRenderProgress=\(progress), lastRenderLoopStage=\(lastRenderLoopStage ?? "none")"
        )
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

        // Diagnóstico real #5: guest CPU/Horizon -> NvServices -> GPU FIFO
        // producer. None of these ever being set after a real device run
        // IS the answer this round is looking for - they are deliberately
        // left at their honest zero/false defaults otherwise, never guessed.
        case "KProcess.Start: main thread created":
            guestMainThreadCreated = true
        case "KProcess.Start: main thread Start result":
            guestMainThreadStarted = (result == "Success")
        case "KThread.ThreadStart: guest Context.Execute begin":
            guestMainThreadAlive = true
            guestExecutionHeartbeats += 1
            if let result, let s = Self.extractField(result, "threadCount"), let n = Int(s) {
                guestThreadCount = max(guestThreadCount, n)
            }
        case "KThread.ThreadStart: guest Context.Execute returned":
            // A guest thread returning during boot (before any real
            // GPU work was ever produced) is anomalous enough to call out
            // explicitly rather than let it blend into the STAGES list.
            log("anomaly: guest Context.Execute returned", result: result)
        case "ARMeilleure.Translator.Execute entered":
            if let result, let s = Self.extractField(result, "threadCount"), let n = Int(s) {
                guestThreadCount = max(guestThreadCount, n)
            }
        case "ARMeilleure first function compiled":
            translatedFunctionsCreated = max(translatedFunctionsCreated, 1)
        case "ARMeilleure first function executed":
            translatedFunctionsExecuted = max(translatedFunctionsExecuted, 1)
        case "GpuContext created":
            gpuContextCreated = true
        case "GPU channel created":
            if let result, let n = Int(result) {
                gpuChannelsCreated = n
            }
        case "SubmitGpfifo ioctl received":
            fifoProducerAlive = true
            if let result, let s = Self.extractField(result, "count"), let n = Int(s) {
                gpfifoSubmissions = n
            }
        case "GPU-FIFO total queued":
            if let result, let n = Int(result) {
                fifoCommandsQueued = n
            }
        case "GPU-FIFO total consumed":
            if let result, let n = Int(result) {
                fifoCommandsConsumed = n
            }
        case "GPU-FIFO WaitForCommands":
            if let result {
                if let s = Self.extractField(result, "waitCalls"), let n = Int(s) { fifoWaitCalls = n }
                if let s = Self.extractField(result, "waitTrue"), let n = Int(s) { fifoWaitTrue = n }
                if let s = Self.extractField(result, "waitFalse"), let n = Int(s) { fifoWaitFalse = n }
            }

        // Diagnóstico real #6: the REAL active translator for this build
        // (Ryujinx.Cpu.LightningJit.Translator - see field doc comments
        // above for why ARMeilleure.Translation.Translator above is not
        // the active path). translatedFunctionsCreated/Executed (declared
        // in the GUEST block) are fed from BOTH paths via max(...) so
        // whichever backend actually runs drives the real number.
        case "LightningJit.Translator.Execute entered":
            contextExecuteEntered = true
            translatorExecuteEntered = true
            if let result, let pc = Self.extractField(result, "pc") {
                firstGuestPc = firstGuestPc ?? pc
                lastGuestPc = pc
            }
        case "LightningJit.Translator.Execute after DispatchLoop":
            contextExecuteReturned = true
        case "LightningJit translate lookup begin":
            // "count" is the real cumulative counter from C# (Interlocked-
            // incremented on EVERY call, independent of log gating) - never
            // approximated from how many events Swift happened to receive,
            // since gating means most calls after the first 10 don't emit
            // a log line at all.
            if let result, let s = Self.extractField(result, "count"), let n = Int(s) {
                translatorLookupAttempts = max(translatorLookupAttempts, n)
            }
            if let result, let pc = Self.extractField(result, "pc") {
                lastGuestPc = pc
                lastTranslatorAddress = pc
            }
        case "LightningJit translate begin":
            if let result, let s = Self.extractField(result, "count"), let n = Int(s) {
                translationAttempts = max(translationAttempts, n)
            }
            if let result, let pc = Self.extractField(result, "pc") {
                lastTranslatorAddress = pc
            }
        case "LightningJit translate compiled":
            if let result, let s = Self.extractField(result, "count"), let n = Int(s) {
                translatedFunctionsCreated = max(translatedFunctionsCreated, n)
            }
            if let result, let pc = Self.extractField(result, "pc") {
                lastTranslatorAddress = pc
            }
        case "LightningJit translate mapped":
            hostFunctionCallAttempted = true
            // Real evidence that the native dispatcher came BACK for a
            // second lookup is the only honest proxy available for "the
            // previously mapped function actually executed and returned" -
            // there is no managed hook inside the generated assembly's
            // jump-to-host-code instruction. See translatorLookupAttempts.
            if translatorLookupAttempts > 1 {
                translatedFunctionsExecuted = max(translatedFunctionsExecuted, translatorLookupAttempts - 1)
                hostFunctionCallReturned = true
            }
        case "LightningJit translate NOP fallback":
            if let result, let s = Self.extractField(result, "count"), let n = Int(s) {
                nopFallbackCount = max(nopFallbackCount, n)
            }
        case "JITMEM allocate":
            jitCodeAllocations += 1
            if let result, let s = Self.extractField(result, "size"), let n = Int(s) {
                jitBytesGenerated += n
            }
        case "JITMEM RW ptr":
            jitRwAddress = result
        case "JITMEM RX ptr":
            jitRxAddress = result
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

        // gpuThreadAlive is deliberately more specific than renderThreadAlive
        // above: it only fires once the GPU.MainThread lambda itself (the
        // thread ThreadedRenderer.RunLoop spawns to run WindowBase.Render()'s
        // while loop) is confirmed entered - not just the GUI.RenderLoop
        // thread that calls RunLoop() in the first place.
        if stage == "GPU.MainThread lambda entered" {
            gpuThreadAlive = true
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

        // Diagnóstico real #5 classification - deliberately separate Sets
        // per layer (guest/kernel, GPU-FIFO producer, NvServices, ARMeilleure
        // translator) even though some events could arguably fit more than
        // one, so "where did we last see activity" stays unambiguous per
        // layer instead of one event clobbering another layer's last stage.
        let guestStages: Set<String> = [
            "KProcess.Start: main thread created", "KProcess.Start: main thread Start result",
            "KThread.ThreadStart: guest Context.Execute begin", "KThread.ThreadStart: guest Context.Execute returned",
        ]
        if guestStages.contains(stage) {
            lastGuestStage = stage
        }

        let gpuProducerStages: Set<String> = [
            "GpuContext created", "GPU channel created",
            "GPU-FIFO enqueue begin", "GPU-FIFO command type", "GPU-FIFO enqueue success", "GPU-FIFO total queued",
            "GPU-FIFO total consumed", "GPU-FIFO WaitForCommands", "GpuChannel.PushEntries called",
        ]
        if gpuProducerStages.contains(stage) {
            lastGpuProducerStage = stage
        }

        let nvStages: Set<String> = [
            "NvHostChannelDeviceFile created", "SubmitGpfifo ioctl received",
            "before Channel.PushEntries", "after GPFifo.SignalNewEntries",
        ]
        if nvStages.contains(stage) {
            lastNvStage = stage
        }

        let translatorStages: Set<String> = [
            "ARMeilleure.Translator.Execute entered", "ARMeilleure first function compiled",
            "ARMeilleure first function executed",
            // Diagnóstico real #6 - the REAL active translator for this
            // build (Ryujinx.Cpu.LightningJit.Translator).
            "LightningJit.Translator.Execute entered", "LightningJit.Translator.Execute before DispatchLoop",
            "LightningJit.Translator.Execute after DispatchLoop",
            "TranslatorStubs.GenerateDispatchStub begin", "TranslatorStubs.GenerateDispatchStub end",
            "TranslatorStubs.GenerateSlowDispatchStub begin", "TranslatorStubs.GenerateSlowDispatchStub end",
            "TranslatorStubs.GenerateDispatchLoop begin", "TranslatorStubs.GenerateDispatchLoop end",
            "TranslatorStubs.Map begin", "TranslatorStubs.Map end",
            "LightningJit translate lookup begin", "LightningJit translate lookup hit",
            "LightningJit translate begin", "LightningJit translate compiled", "LightningJit translate mapped",
            "LightningJit translate NOP fallback",
            "JITMEM allocate", "JITMEM RW ptr", "JITMEM RX ptr", "JITMEM cache flush begin", "JITMEM cache flush end",
        ]
        if translatorStages.contains(stage) {
            lastTranslatorStage = stage
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
        lines.append("GUEST:")
        lines.append("guestMainThreadCreated = \(guestMainThreadCreated)")
        lines.append("guestMainThreadStarted = \(guestMainThreadStarted)")
        lines.append("guestMainThreadAlive = \(guestMainThreadAlive)")
        lines.append("guestThreadCount = \(guestThreadCount)")
        lines.append("guestExecutionHeartbeats = \(guestExecutionHeartbeats)")
        lines.append("translatedFunctionsCreated = \(translatedFunctionsCreated)")
        lines.append("translatedFunctionsExecuted = \(translatedFunctionsExecuted)")
        lines.append("lastGuestStage = \(lastGuestStage ?? "none")")
        lines.append("")
        lines.append("GPU PRODUCER:")
        lines.append("gpuContextCreated = \(gpuContextCreated)")
        lines.append("gpuChannelsCreated = \(gpuChannelsCreated)")
        lines.append("gpfifoSubmissions = \(gpfifoSubmissions)")
        lines.append("fifoCommandsQueued = \(fifoCommandsQueued)")
        lines.append("fifoCommandsConsumed = \(fifoCommandsConsumed)")
        lines.append("fifoWaitCalls = \(fifoWaitCalls)")
        lines.append("fifoWaitTrue = \(fifoWaitTrue)")
        lines.append("fifoWaitFalse = \(fifoWaitFalse)")
        lines.append("lastGpuProducerStage = \(lastGpuProducerStage ?? "none")")
        lines.append("lastNvStage = \(lastNvStage ?? "none")")
        lines.append("lastTranslatorStage = \(lastTranslatorStage ?? "none")")
        lines.append("")
        lines.append("TRANSLATOR (real active backend - Ryujinx.Cpu.LightningJit on this build):")
        lines.append("contextExecuteEntered = \(contextExecuteEntered)")
        lines.append("contextExecuteReturned = \(contextExecuteReturned)")
        lines.append("translatorExecuteEntered = \(translatorExecuteEntered)")
        lines.append("translatorLookupAttempts = \(translatorLookupAttempts)")
        lines.append("translationAttempts = \(translationAttempts)")
        lines.append("nopFallbackCount = \(nopFallbackCount)")
        lines.append("jitCodeAllocations = \(jitCodeAllocations)")
        lines.append("jitBytesGenerated = \(jitBytesGenerated)")
        lines.append("firstGuestPc = \(firstGuestPc ?? "none")")
        lines.append("lastGuestPc = \(lastGuestPc ?? "none")")
        lines.append("lastTranslatorAddress = \(lastTranslatorAddress ?? "none")")
        lines.append("jitRwAddress = \(jitRwAddress ?? "none")")
        lines.append("jitRxAddress = \(jitRxAddress ?? "none")")
        lines.append("hostFunctionCallAttempted = \(hostFunctionCallAttempted)")
        lines.append("hostFunctionCallReturned = \(hostFunctionCallReturned)")
        lines.append("")
        lines.append("RENDERER:")
        lines.append("renderLoopIterations = \(renderLoopIterations)")
        lines.append("acquireAttemptCount = \(acquireAttemptCount)")
        lines.append("firstAcquireSucceeded = \(firstAcquireSucceeded)")
        lines.append("lastAcquireResult = \(lastAcquireResult ?? "none")")
        lines.append("lastSubmitResult = \(lastSubmitResult ?? "none")")
        lines.append("lastPresentResult = \(lastPresentResult ?? "none")")
        lines.append("")
        lines.append("THREAD SNAPSHOT:")
        lines.append("gpuThreadAlive = \(gpuThreadAlive)")
        lines.append("fifoProducerAlive = \(fifoProducerAlive)")
        lines.append("guestMainThreadAlive = \(guestMainThreadAlive)")
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
