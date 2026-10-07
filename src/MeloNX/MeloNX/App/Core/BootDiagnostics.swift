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

    // Diagnóstico real #7: isolating WHERE inside LightningJit execution
    // actually stops - DispatchLoop delegate resolution/call (FASE 1), a
    // same-map probe proving the dual-mapping/icache/invocation mechanism
    // itself works (FASE 2), native stage markers written directly by the
    // generated ARM64 code (FASE 3), an opt-in direct-dispatch probe (FASE 4),
    // the earliest possible GetFunctionAddress marker (FASE 5), a read-only
    // FunctionTable snapshot (FASE 6), and RW/RX byte-level verification
    // (FASE 7, extends jitRwAddress/jitRxAddress above with actual content).
    @Published private(set) var dispatchLoopResolved = false
    @Published private(set) var dispatchLoopPointer: String?
    @Published private(set) var dispatchLoopCallBegan = false
    @Published private(set) var dispatchLoopCallReturned = false

    // FASE 3: raw native stage values (see TranslatorStubs.EmitDiagMarker) -
    // 0 means "never written", polled from native memory while DispatchLoop
    // runs (see Translator.PollDiagMarkers), not something C# sets directly.
    @Published private(set) var dispatchLoopNativeStage = 0
    @Published private(set) var dispatchStubStage = 0
    @Published private(set) var slowDispatchStubStage = 0
    var dispatchStubEntered: Bool { dispatchStubStage > 0 }
    var slowDispatchStubEntered: Bool { slowDispatchStubStage > 0 }

    // FASE 2: same-map probe (generates/maps/calls a tiny known function
    // through the EXACT cache DispatchLoop uses, expects 0x12345678 back).
    @Published private(set) var dispatchProbeRwAddress: String?
    @Published private(set) var dispatchProbeRxAddress: String?
    @Published private(set) var dispatchProbeCallAttempted = false
    @Published private(set) var dispatchProbeReturned = false
    @Published private(set) var dispatchProbeReturnValue: String?
    @Published private(set) var dispatchProbeBytesWritten: String?
    @Published private(set) var dispatchProbeBytesReadBack: String?
    @Published private(set) var dispatchProbePassed: Bool?

    // FASE 5: earliest possible marker inside NativeInterface.GetFunctionAddress.
    @Published private(set) var nativeGetFunctionAddressEntered = false
    @Published private(set) var nativeGetFunctionAddressCalls = 0
    @Published private(set) var nativeGetFunctionAddressAddress: String?
    @Published private(set) var nativeGetFunctionAddressFramePointer: String?

    // FASE 6: read-only FunctionTable snapshot for the first guest PC.
    @Published private(set) var functionTableBase: String?
    @Published private(set) var functionTableMask: String?
    @Published private(set) var functionTableFill: String?
    @Published private(set) var functionTableLevelCount: Int?
    @Published private(set) var functionTableDispatchStubPtr: String?
    @Published private(set) var functionTableSlowDispatchStubPtr: String?
    @Published private(set) var functionTableAddressInRange: Bool?
    @Published private(set) var functionTableLevelIndices: String?

    // FASE 4: off by default (LIGHTNINGJIT_DIAG_DIRECT_DISPATCH=1 required).
    @Published private(set) var directDispatchProbeAttempted = false
    @Published private(set) var directDispatchProbeResult: String?

    // FASE 7: byte-level RW/RX coherence check on the real (non-probe)
    // guest-function mapping path, extending jitRwAddress/jitRxAddress above.
    @Published private(set) var jitMemBytesWritten: String?
    @Published private(set) var jitMemBytesReadBack: String?
    @Published private(set) var jitMemBytesMatch: Bool?

    // Diagnóstico real #8: dispatchProbeCallAttempted=true but
    // dispatchProbeReturned=false on real device - isolating WHY a tiny
    // ARM64 function written through the dual-mapped RW alias and invoked
    // through the RX alias never returns (FASES 8A-8G).
    @Published private(set) var dispatchProbeBytesRw: String?
    @Published private(set) var dispatchProbeBytesRx: String?
    @Published private(set) var dispatchProbeRwRxBytesMatch: Bool?
    @Published private(set) var dispatchProbeCoherencePatternAMatch: Bool?
    @Published private(set) var dispatchProbeCoherencePatternBMatch: Bool?

    // FASE 8B: real current/max protection, queried via mach_vm_region -
    // never assumed from Map()/vm_protect having returned success.
    @Published private(set) var dispatchProbeRwCurrentProtection: String?
    @Published private(set) var dispatchProbeRwMaxProtection: String?
    @Published private(set) var dispatchProbeRxCurrentProtection: String?
    @Published private(set) var dispatchProbeRxMaxProtection: String?

    // FASE 8C: explicit cache sync right before the call, targeting the RX
    // alias specifically (not only RW).
    @Published private(set) var dispatchProbeDcacheFlushRwAttempted = false
    @Published private(set) var dispatchProbeIcacheInvalidateRwAttempted = false
    @Published private(set) var dispatchProbeIcacheInvalidateRxAttempted = false
    @Published private(set) var dispatchProbeCacheSyncCompleted: Bool?

    // FASE 8D: libc's real getpid(), called through the EXACT SAME
    // Marshal.GetDelegateForFunctionPointer mechanism as the probe itself -
    // isolates the managed call/delegate/ABI layer from DualMappedNoWxCache.
    @Published private(set) var nativeControlPointer: String?
    @Published private(set) var nativeControlCallAttempted = false
    @Published private(set) var nativeControlReturned = false
    @Published private(set) var nativeControlReturnValue: String?
    @Published private(set) var nativeControlPassed: Bool?

    // FASE 8E: the SAME 8 bytes, classic single mmap-RW/mprotect-RX (no
    // dual alias), called through the SAME delegate mechanism.
    @Published private(set) var singleMapRwAddress: String?
    @Published private(set) var singleMapExecAddress: String?
    @Published private(set) var singleMapBytesReadBack: String?
    @Published private(set) var singleMapCallAttempted = false
    @Published private(set) var singleMapReturned = false
    @Published private(set) var singleMapReturnValue: String?
    @Published private(set) var singleMapPassed: Bool?

    // FASE 8F: real CPU subtype via sysctlbyname - RuntimeInformation.
    // ProcessArchitecture alone cannot distinguish arm64 from arm64e.
    @Published private(set) var processArchitecture: String?
    @Published private(set) var isArm64e: String?
    @Published private(set) var pointerAuthenticationRelevant: String?

    // FASE 8G: a SEPARATE stage-marker variant of the same-map probe, run
    // on its own background thread precisely so a hang here is still
    // observable without blocking the real DispatchLoop attempt.
    @Published private(set) var sameMapNativeEntryStage = 0
    @Published private(set) var sameMapNativeBeforeRetStage = 0

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
            self.dispatchLoopResolved = false
            self.dispatchLoopPointer = nil
            self.dispatchLoopCallBegan = false
            self.dispatchLoopCallReturned = false
            self.dispatchLoopNativeStage = 0
            self.dispatchStubStage = 0
            self.slowDispatchStubStage = 0
            self.dispatchProbeRwAddress = nil
            self.dispatchProbeRxAddress = nil
            self.dispatchProbeCallAttempted = false
            self.dispatchProbeReturned = false
            self.dispatchProbeReturnValue = nil
            self.dispatchProbeBytesWritten = nil
            self.dispatchProbeBytesReadBack = nil
            self.dispatchProbePassed = nil
            self.nativeGetFunctionAddressEntered = false
            self.nativeGetFunctionAddressCalls = 0
            self.nativeGetFunctionAddressAddress = nil
            self.nativeGetFunctionAddressFramePointer = nil
            self.functionTableBase = nil
            self.functionTableMask = nil
            self.functionTableFill = nil
            self.functionTableLevelCount = nil
            self.functionTableDispatchStubPtr = nil
            self.functionTableSlowDispatchStubPtr = nil
            self.functionTableAddressInRange = nil
            self.functionTableLevelIndices = nil
            self.directDispatchProbeAttempted = false
            self.directDispatchProbeResult = nil
            self.jitMemBytesWritten = nil
            self.jitMemBytesReadBack = nil
            self.jitMemBytesMatch = nil
            self.dispatchProbeBytesRw = nil
            self.dispatchProbeBytesRx = nil
            self.dispatchProbeRwRxBytesMatch = nil
            self.dispatchProbeCoherencePatternAMatch = nil
            self.dispatchProbeCoherencePatternBMatch = nil
            self.dispatchProbeRwCurrentProtection = nil
            self.dispatchProbeRwMaxProtection = nil
            self.dispatchProbeRxCurrentProtection = nil
            self.dispatchProbeRxMaxProtection = nil
            self.dispatchProbeDcacheFlushRwAttempted = false
            self.dispatchProbeIcacheInvalidateRwAttempted = false
            self.dispatchProbeIcacheInvalidateRxAttempted = false
            self.dispatchProbeCacheSyncCompleted = nil
            self.nativeControlPointer = nil
            self.nativeControlCallAttempted = false
            self.nativeControlReturned = false
            self.nativeControlReturnValue = nil
            self.nativeControlPassed = nil
            self.singleMapRwAddress = nil
            self.singleMapExecAddress = nil
            self.singleMapBytesReadBack = nil
            self.singleMapCallAttempted = false
            self.singleMapReturned = false
            self.singleMapReturnValue = nil
            self.singleMapPassed = nil
            self.processArchitecture = nil
            self.isArm64e = nil
            self.pointerAuthenticationRelevant = nil
            self.sameMapNativeEntryStage = 0
            self.sameMapNativeBeforeRetStage = 0
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

        // Diagnóstico real #7: once translatedFunctionsCreated==0 (the real
        // LightningJit backend never produced a single translated
        // function), distinguish A-F from the user's exact enumeration
        // using the FASE 1-6 evidence, instead of a single generic bucket.
        if translatedFunctionsCreated == 0 && gpfifoSubmissions == 0 {
            // Diagnóstico real #8: the probe either returned the wrong
            // value (dispatchProbePassed == false) or never returned at
            // all (dispatchProbeCallAttempted but !dispatchProbeReturned -
            // the real device scenario this round is built around).
            // Sub-classify A1-A7 using the FASE 8A-8G evidence, in order of
            // how certain/fundamental each diagnosis is - never a guess.
            if dispatchProbePassed == false || (dispatchProbeCallAttempted && !dispatchProbeReturned) {
                if dispatchProbeRwRxBytesMatch == false {
                    return (
                        "A1 - RX bytes differ from RW",
                        "the RX alias does NOT show the same bytes that were written through RW; dispatchProbeBytesRw=\(dispatchProbeBytesRw ?? "none"), dispatchProbeBytesRx=\(dispatchProbeBytesRx ?? "none") - RW/RX are not really aliasing the same backing memory, or the read happened before the write was visible"
                    )
                }

                if let rxProt = dispatchProbeRxCurrentProtection, !rxProt.contains("EXECUTE") {
                    return (
                        "A2 - RX lacks execute protection",
                        "mach_vm_region reports the RX address's REAL current protection as \"\(rxProt)\" (no EXECUTE), right before the call - Map()/vm_protect succeeding earlier never proved this; max=\(dispatchProbeRxMaxProtection ?? "none")"
                    )
                }

                if nativeControlPassed == false {
                    return (
                        "A4 - native/control calling mechanism failure",
                        "calling libc's real getpid() through the EXACT SAME Marshal.GetDelegateForFunctionPointer mechanism also failed/hung (nativeControlReturned=\(nativeControlReturned), nativeControlReturnValue=\(nativeControlReturnValue ?? "none")) - the problem is in the managed call/delegate/ABI layer itself, not specific to DualMappedNoWxCache"
                    )
                }

                if singleMapPassed == true {
                    return (
                        "A5 - single-map executes but dual-map hangs",
                        "the exact same instruction bytes ran correctly (singleMapReturnValue=\(singleMapReturnValue ?? "none")) through a classic single mmap-RW/mprotect-RX region with no dual alias, but the dual-mapped version did not - the bug is specific to the dual-mapping/remap mechanism (DualMappedJitAllocator), not to code generation, the calling convention, or ABI"
                    )
                }

                if sameMapNativeEntryStage > 0 && sameMapNativeBeforeRetStage == 0 {
                    return (
                        "A6 - generated code entered but RET never completed",
                        "the stage-marker probe variant (same cache/mapping) wrote its entry marker (sameMapNativeEntryStage=\(sameMapNativeEntryStage)) but never reached the marker right before RET - execution started inside the generated/mapped code and then got stuck, crashed without a managed exception, or jumped somewhere unexpected before reaching RET"
                    )
                }

                if dispatchProbeCacheSyncCompleted == false {
                    return (
                        "A3 - cache synchronization problem",
                        "the explicit dcache-flush/icache-invalidate sequence (targeting the RX alias, not only RW) did not complete cleanly; dcacheFlushRwAttempted=\(dispatchProbeDcacheFlushRwAttempted), icacheInvalidateRwAttempted=\(dispatchProbeIcacheInvalidateRwAttempted), icacheInvalidateRxAttempted=\(dispatchProbeIcacheInvalidateRxAttempted)"
                    )
                }

                if isArm64e == "true" {
                    return (
                        "A7 - possible arm64e/PAC indirect-call issue",
                        "this process is running as arm64e (pointerAuthenticationRelevant=true) - a function pointer produced manually from the RX alias may need pointer-authentication treatment before an indirect call/branch that this probe does not apply; nativeControlPassed=\(nativeControlPassed.map { "\($0)" } ?? "unknown") (if that also failed, prefer A4 instead - this is only reached when the control call itself succeeded)"
                    )
                }

                return (
                    "Scenario A - dual mapping / icache / invocación de código generado",
                    "the same-map probe (known function through the exact same cache DispatchLoop uses) did not complete successfully, but none of A1/A2/A3/A4/A5/A6/A7's specific evidence matched; dispatchProbeReturned=\(dispatchProbeReturned), dispatchProbeReturnValue=\(dispatchProbeReturnValue ?? "none"), dispatchProbeCallAttempted=\(dispatchProbeCallAttempted) - see the full report's \"DUAL-MAP PROBE HANG INVESTIGATION\" section for every FASE 8A-8G field"
                )
            }

            if dispatchLoopCallBegan && dispatchLoopNativeStage == 0 {
                return (
                    "Scenario B - entrando al delegate/function pointer de DispatchLoop",
                    "CALL BEGIN was logged (the managed delegate call was issued) but DispatchLoop's native code never wrote its first stage marker; dispatchLoopPointer=\(dispatchLoopPointer ?? "none"), dispatchProbePassed=\(dispatchProbePassed.map { "\($0)" } ?? "unknown") (probe passing would mean the jump mechanism itself works, so the problem is specific to this particular call/pointer)"
                )
            }

            if dispatchLoopNativeStage >= 1 && dispatchLoopNativeStage < 4 && dispatchStubStage == 0 {
                return (
                    "Scenario C - primeras instrucciones de DispatchLoop, antes de llegar a DispatchStub",
                    "dispatchLoopNativeStage=\(dispatchLoopNativeStage) (never reached 4 = \"antes de BLR DispatchStub\"); dispatchStubEntered=\(dispatchStubEntered)"
                )
            }

            if dispatchLoopNativeStage >= 4 && dispatchStubStage == 0 {
                return (
                    "Scenario C-D boundary - BLR DispatchStub fue emitido pero DispatchStub nunca escribió su primer marcador",
                    "dispatchLoopNativeStage=\(dispatchLoopNativeStage) (reached the BLR) but dispatchStubStage=0 - the jump into DispatchStub itself may not be landing"
                )
            }

            if dispatchStubStage > 0 && !nativeGetFunctionAddressEntered {
                return (
                    "Scenario D - FunctionTable/fallback/BLR dentro de DispatchStub",
                    "dispatchStubStage=\(dispatchStubStage) (entered DispatchStub) but NativeInterface.GetFunctionAddress was never reached; functionTableAddressInRange=\(functionTableAddressInRange.map { "\($0)" } ?? "unknown"), functionTableLevelIndices=\(functionTableLevelIndices ?? "none")"
                )
            }

            if nativeGetFunctionAddressEntered && translationAttempts == 0 {
                return (
                    "Scenario E - NativeInterface.GetFunctionAddress / GetOrTranslate",
                    "GetFunctionAddress was entered (calls=\(nativeGetFunctionAddressCalls)) but GetOrTranslatePointer never reached a real Translate attempt; nopFallbackCount=\(nopFallbackCount) (a non-zero count here means it DID try and fell back to a NOP, not that it never tried)"
                )
            }

            return (
                "guest CPU / translator startup",
                "guest execution entered Context.Execute but no translated function was created or executed; translatorExecuteEntered=\(translatorExecuteEntered), translatorLookupAttempts=\(translatorLookupAttempts), translationAttempts=\(translationAttempts), nopFallbackCount=\(nopFallbackCount), lastTranslatorStage=\(lastTranslatorStage ?? "none")"
            )
        }

        if gpfifoSubmissions == 0 {
            if translatedFunctionsCreated > 0 && !hostFunctionCallReturned {
                return (
                    "Scenario F - segundo salto hacia código JIT generado",
                    "translatedFunctionsCreated=\(translatedFunctionsCreated) but the native dispatcher never came back for a second lookup (hostFunctionCallReturned=false) - the first translated function may be stuck executing, crashed silently, or never actually ran despite being mapped; dispatchStubStage=\(dispatchStubStage)"
                )
            }

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
        case "JITMEM bytes written (RW)":
            jitMemBytesWritten = result
        case "JITMEM bytes read back (RX alias)":
            jitMemBytesReadBack = result
        case "JITMEM RW/RX bytes match":
            jitMemBytesMatch = (result == "true")

        // Diagnóstico real #7: isolating exactly where inside LightningJit
        // execution progress stops (FASES 1-7, see field doc comments above).
        case "LightningJit.DispatchLoop resolve end":
            dispatchLoopResolved = true
        case "LightningJit.DispatchLoop pointer":
            dispatchLoopPointer = result
        case "LightningJit.DispatchLoop CALL BEGIN":
            dispatchLoopCallBegan = true
        case "LightningJit.DispatchLoop CALL RETURNED":
            dispatchLoopCallReturned = true
        case "LightningJit.dispatchLoopNativeStage":
            if let result, let n = Int(result) { dispatchLoopNativeStage = n }
        case "LightningJit.dispatchStubStage":
            if let result, let n = Int(result) { dispatchStubStage = n }
        case "LightningJit.slowDispatchStubStage":
            if let result, let n = Int(result) { slowDispatchStubStage = n }
        case "LightningJit.SameMapProbe mapped":
            if let result {
                dispatchProbeRwAddress = Self.extractField(result, "rw")
                dispatchProbeRxAddress = Self.extractField(result, "rx")
            }
        case "LightningJit.SameMapProbe bytes written":
            dispatchProbeBytesWritten = result
        case "LightningJit.SameMapProbe bytes read back (RW alias)":
            dispatchProbeBytesReadBack = result
            dispatchProbeBytesRw = result
        case "LightningJit.SameMapProbe call begin":
            dispatchProbeCallAttempted = true
        case "LightningJit.SameMapProbe call returned":
            dispatchProbeReturned = true
            if let result { dispatchProbeReturnValue = Self.extractField(result, "result") }
        case "LightningJit.SameMapProbe PASS":
            dispatchProbePassed = true
        case "LightningJit.SameMapProbe FAIL":
            dispatchProbePassed = false
        case "NativeInterface.GetFunctionAddress entered":
            nativeGetFunctionAddressEntered = true
            if let result {
                if let s = Self.extractField(result, "calls"), let n = Int(s) {
                    nativeGetFunctionAddressCalls = max(nativeGetFunctionAddressCalls, n)
                }
                nativeGetFunctionAddressAddress = Self.extractField(result, "address")
                nativeGetFunctionAddressFramePointer = Self.extractField(result, "framePointer")
            }
        case "LightningJit.FunctionTable info":
            if let result {
                functionTableBase = Self.extractField(result, "base")
                functionTableMask = Self.extractField(result, "mask")
                functionTableFill = Self.extractField(result, "fill")
                if let s = Self.extractField(result, "levelCount"), let n = Int(s) {
                    functionTableLevelCount = n
                }
            }
        case "LightningJit.FunctionTable stubs":
            if let result {
                functionTableDispatchStubPtr = Self.extractField(result, "dispatchStub")
                functionTableSlowDispatchStubPtr = Self.extractField(result, "slowDispatchStub")
            }
        case "LightningJit.FunctionTable lookup":
            if let result, let s = Self.extractField(result, "inRange") {
                functionTableAddressInRange = (s == "true")
            }
        case "LightningJit.FunctionTable level indices":
            functionTableLevelIndices = result
        case "LightningJit.DirectDispatchProbe begin":
            directDispatchProbeAttempted = true
        case "LightningJit.DirectDispatchProbe result":
            if let result { directDispatchProbeResult = Self.extractField(result, "hostFuncPtr") }

        // Diagnóstico real #8 (FASES 8A-8G).
        case "dispatchProbeBytesRx":
            dispatchProbeBytesRx = result
        case "dispatchProbeRwRxBytesMatch":
            dispatchProbeRwRxBytesMatch = (result == "true")
        case "LightningJit.SameMapProbe coherence pattern A":
            if let result, let s = Self.extractField(result, "match") { dispatchProbeCoherencePatternAMatch = (s == "true") }
        case "LightningJit.SameMapProbe coherence pattern B":
            if let result, let s = Self.extractField(result, "match") { dispatchProbeCoherencePatternBMatch = (s == "true") }
        case "NativeMemoryDiagnostics.QueryProtection RW":
            if let result {
                dispatchProbeRwCurrentProtection = Self.extractField(result, "current")
                dispatchProbeRwMaxProtection = Self.extractField(result, "max")
            }
        case "NativeMemoryDiagnostics.QueryProtection RX":
            if let result {
                dispatchProbeRxCurrentProtection = Self.extractField(result, "current")
                dispatchProbeRxMaxProtection = Self.extractField(result, "max")
            }
        case "dispatchProbeDcacheFlushRwAttempted":
            dispatchProbeDcacheFlushRwAttempted = true
        case "dispatchProbeIcacheInvalidateRwAttempted":
            dispatchProbeIcacheInvalidateRwAttempted = true
        case "dispatchProbeIcacheInvalidateRxAttempted":
            dispatchProbeIcacheInvalidateRxAttempted = true
        case "dispatchProbeCacheSyncCompleted":
            dispatchProbeCacheSyncCompleted = (result == "true")
        case "nativeControlPointer":
            nativeControlPointer = result
        case "nativeControlCallAttempted":
            nativeControlCallAttempted = (result == "true")
        case "nativeControlReturned":
            nativeControlReturned = (result == "true")
        case "nativeControlReturnValue":
            nativeControlReturnValue = result
        case "nativeControlPassed":
            nativeControlPassed = (result == "true")
        case "singleMapRwAddress":
            singleMapRwAddress = result
        case "singleMapExecAddress":
            singleMapExecAddress = result
        case "singleMapBytesReadBack":
            singleMapBytesReadBack = result
        case "singleMapCallAttempted":
            singleMapCallAttempted = (result == "true")
        case "singleMapReturned":
            singleMapReturned = (result == "true")
        case "singleMapReturnValue":
            singleMapReturnValue = result
        case "singleMapPassed":
            singleMapPassed = (result == "true")
        case "processArchitecture":
            processArchitecture = result
        case "isArm64e":
            isArm64e = result
        case "pointerAuthenticationRelevant":
            pointerAuthenticationRelevant = result
        case "sameMapNativeEntryStage":
            if let result, let n = Int(result) { sameMapNativeEntryStage = n }
        case "sameMapNativeBeforeRetStage":
            if let result, let n = Int(result) { sameMapNativeBeforeRetStage = n }
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
            "JITMEM bytes written (RW)", "JITMEM bytes read back (RX alias)", "JITMEM RW/RX bytes match",
            // Diagnóstico real #7 (FASES 1-7).
            "LightningJit.DispatchLoop resolve begin", "LightningJit.DispatchLoop resolve end",
            "LightningJit.DispatchLoop pointer", "LightningJit.DispatchLoop CALL BEGIN", "LightningJit.DispatchLoop CALL RETURNED",
            "LightningJit.dispatchLoopNativeStage", "LightningJit.dispatchStubStage", "LightningJit.slowDispatchStubStage",
            "LightningJit.SameMapProbe begin", "LightningJit.SameMapProbe mapped",
            "LightningJit.SameMapProbe bytes written", "LightningJit.SameMapProbe bytes read back (RW alias)",
            "LightningJit.SameMapProbe call begin", "LightningJit.SameMapProbe call returned",
            "LightningJit.SameMapProbe PASS", "LightningJit.SameMapProbe FAIL",
            "NativeInterface.GetFunctionAddress entered", "NativeInterface.GetFunctionAddress returning",
            "LightningJit.FunctionTable info", "LightningJit.FunctionTable stubs",
            "LightningJit.FunctionTable lookup", "LightningJit.FunctionTable level indices",
            "LightningJit.DirectDispatchProbe begin", "LightningJit.DirectDispatchProbe result",
            // Diagnóstico real #8 (FASES 8A-8G).
            "dispatchProbeBytesRx", "dispatchProbeRwRxBytesMatch",
            "LightningJit.SameMapProbe coherence pattern A", "LightningJit.SameMapProbe coherence pattern B",
            "NativeMemoryDiagnostics.QueryProtection RW", "NativeMemoryDiagnostics.QueryProtection RX",
            "dispatchProbeDcacheFlushRwAttempted", "dispatchProbeIcacheInvalidateRwAttempted",
            "dispatchProbeIcacheInvalidateRxAttempted", "dispatchProbeCacheSyncCompleted",
            "nativeControlPointer", "nativeControlCallAttempted", "nativeControlReturned",
            "nativeControlReturnValue", "nativeControlPassed",
            "singleMapRwAddress", "singleMapExecAddress", "singleMapBytesReadBack",
            "singleMapCallAttempted", "singleMapReturned", "singleMapReturnValue", "singleMapPassed",
            "processArchitecture", "isArm64e", "pointerAuthenticationRelevant",
            "sameMapNativeEntryStage", "sameMapNativeBeforeRetStage",
            "LightningJit.SameMapStageProbe call begin", "LightningJit.SameMapStageProbe call returned",
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
        lines.append("DISPATCH (FASE 1 - DispatchLoop delegate resolve/call):")
        lines.append("dispatchLoopResolved = \(dispatchLoopResolved)")
        lines.append("dispatchLoopPointer = \(dispatchLoopPointer ?? "none")")
        lines.append("dispatchLoopCallBegan = \(dispatchLoopCallBegan)")
        lines.append("dispatchLoopCallReturned = \(dispatchLoopCallReturned)")
        lines.append("")
        lines.append("NATIVE STAGE MARKERS (FASE 3 - written by generated ARM64 code itself):")
        lines.append("dispatchLoopNativeStage = \(dispatchLoopNativeStage)")
        lines.append("dispatchStubStage = \(dispatchStubStage)")
        lines.append("dispatchStubEntered = \(dispatchStubEntered)")
        lines.append("slowDispatchStubStage = \(slowDispatchStubStage)")
        lines.append("slowDispatchStubEntered = \(slowDispatchStubEntered)")
        lines.append("")
        lines.append("SAME-MAP PROBE (FASE 2 - known-constant function through the exact same cache):")
        lines.append("dispatchProbeRwAddress = \(dispatchProbeRwAddress ?? "none")")
        lines.append("dispatchProbeRxAddress = \(dispatchProbeRxAddress ?? "none")")
        lines.append("dispatchProbeCallAttempted = \(dispatchProbeCallAttempted)")
        lines.append("dispatchProbeReturned = \(dispatchProbeReturned)")
        lines.append("dispatchProbeReturnValue = \(dispatchProbeReturnValue ?? "none")")
        lines.append("dispatchProbePassed = \(dispatchProbePassed.map { "\($0)" } ?? "unknown")")
        lines.append("dispatchProbeBytesWritten = \(dispatchProbeBytesWritten ?? "none")")
        lines.append("dispatchProbeBytesReadBack = \(dispatchProbeBytesReadBack ?? "none")")
        lines.append("")
        lines.append("NativeInterface.GetFunctionAddress (FASE 5 - earliest possible marker):")
        lines.append("nativeGetFunctionAddressEntered = \(nativeGetFunctionAddressEntered)")
        lines.append("nativeGetFunctionAddressCalls = \(nativeGetFunctionAddressCalls)")
        lines.append("nativeGetFunctionAddressAddress = \(nativeGetFunctionAddressAddress ?? "none")")
        lines.append("nativeGetFunctionAddressFramePointer = \(nativeGetFunctionAddressFramePointer ?? "none")")
        lines.append("")
        lines.append("FUNCTION TABLE (FASE 6 - read-only snapshot for the first guest PC):")
        lines.append("functionTableBase = \(functionTableBase ?? "none")")
        lines.append("functionTableMask = \(functionTableMask ?? "none")")
        lines.append("functionTableFill = \(functionTableFill ?? "none")")
        lines.append("functionTableLevelCount = \(functionTableLevelCount.map { "\($0)" } ?? "none")")
        lines.append("functionTableDispatchStubPtr = \(functionTableDispatchStubPtr ?? "none")")
        lines.append("functionTableSlowDispatchStubPtr = \(functionTableSlowDispatchStubPtr ?? "none")")
        lines.append("functionTableAddressInRange = \(functionTableAddressInRange.map { "\($0)" } ?? "unknown")")
        lines.append("functionTableLevelIndices = \(functionTableLevelIndices ?? "none")")
        lines.append("")
        lines.append("DIRECT-DISPATCH PROBE (FASE 4 - off unless LIGHTNINGJIT_DIAG_DIRECT_DISPATCH=1):")
        lines.append("directDispatchProbeAttempted = \(directDispatchProbeAttempted)")
        lines.append("directDispatchProbeResult = \(directDispatchProbeResult ?? "none")")
        lines.append("")
        lines.append("JITMEM BYTE VERIFICATION (FASE 7 - real guest-function mapping path):")
        lines.append("jitMemBytesWritten = \(jitMemBytesWritten ?? "none")")
        lines.append("jitMemBytesReadBack = \(jitMemBytesReadBack ?? "none")")
        lines.append("jitMemBytesMatch = \(jitMemBytesMatch.map { "\($0)" } ?? "unknown")")
        lines.append("")
        lines.append("DUAL-MAP PROBE HANG INVESTIGATION (FASES 8A-8G):")
        lines.append("dispatchProbeBytesRw = \(dispatchProbeBytesRw ?? "none")")
        lines.append("dispatchProbeBytesRx = \(dispatchProbeBytesRx ?? "none")")
        lines.append("dispatchProbeRwRxBytesMatch = \(dispatchProbeRwRxBytesMatch.map { "\($0)" } ?? "unknown")")
        lines.append("dispatchProbeCoherencePatternAMatch = \(dispatchProbeCoherencePatternAMatch.map { "\($0)" } ?? "unknown")")
        lines.append("dispatchProbeCoherencePatternBMatch = \(dispatchProbeCoherencePatternBMatch.map { "\($0)" } ?? "unknown")")
        lines.append("dispatchProbeRwCurrentProtection = \(dispatchProbeRwCurrentProtection ?? "none")")
        lines.append("dispatchProbeRwMaxProtection = \(dispatchProbeRwMaxProtection ?? "none")")
        lines.append("dispatchProbeRxCurrentProtection = \(dispatchProbeRxCurrentProtection ?? "none")")
        lines.append("dispatchProbeRxMaxProtection = \(dispatchProbeRxMaxProtection ?? "none")")
        lines.append("dispatchProbeDcacheFlushRwAttempted = \(dispatchProbeDcacheFlushRwAttempted)")
        lines.append("dispatchProbeIcacheInvalidateRwAttempted = \(dispatchProbeIcacheInvalidateRwAttempted)")
        lines.append("dispatchProbeIcacheInvalidateRxAttempted = \(dispatchProbeIcacheInvalidateRxAttempted)")
        lines.append("dispatchProbeCacheSyncCompleted = \(dispatchProbeCacheSyncCompleted.map { "\($0)" } ?? "unknown")")
        lines.append("nativeControlPointer = \(nativeControlPointer ?? "none")")
        lines.append("nativeControlCallAttempted = \(nativeControlCallAttempted)")
        lines.append("nativeControlReturned = \(nativeControlReturned)")
        lines.append("nativeControlReturnValue = \(nativeControlReturnValue ?? "none")")
        lines.append("nativeControlPassed = \(nativeControlPassed.map { "\($0)" } ?? "unknown")")
        lines.append("singleMapRwAddress = \(singleMapRwAddress ?? "none")")
        lines.append("singleMapExecAddress = \(singleMapExecAddress ?? "none")")
        lines.append("singleMapBytesReadBack = \(singleMapBytesReadBack ?? "none")")
        lines.append("singleMapCallAttempted = \(singleMapCallAttempted)")
        lines.append("singleMapReturned = \(singleMapReturned)")
        lines.append("singleMapReturnValue = \(singleMapReturnValue ?? "none")")
        lines.append("singleMapPassed = \(singleMapPassed.map { "\($0)" } ?? "unknown")")
        lines.append("processArchitecture = \(processArchitecture ?? "none")")
        lines.append("isArm64e = \(isArm64e ?? "unknown")")
        lines.append("pointerAuthenticationRelevant = \(pointerAuthenticationRelevant ?? "unknown")")
        lines.append("sameMapNativeEntryStage = \(sameMapNativeEntryStage)")
        lines.append("sameMapNativeBeforeRetStage = \(sameMapNativeBeforeRetStage)")
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
