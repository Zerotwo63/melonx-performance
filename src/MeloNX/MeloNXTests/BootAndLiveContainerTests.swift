//
//  BootAndLiveContainerTests.swift
//  MeloNXTests
//

import Testing
@testable import MeloNX

/// Covers the LiveContainer/boot refactor: enableJIT() must never attempt
/// an internal JIT method while running inside LiveContainer, startGame()
/// must not race ahead of JIT confirmation, JITCoordinator must cancel
/// polling on a definitive failure instead of waiting out its cap, and
/// BootDiagnostics must track/report the boot sequence correctly.
///
/// `.serialized`: JITCoordinator/BootDiagnostics are singletons with
/// shared mutable state, same reasoning as JITFlowTests.
@Suite(.serialized)
struct BootAndLiveContainerTests {
    // MARK: - RuntimeEnvironment

    @Test func runtimeEnvironmentReflectsGlobalFlag() {
        let original = isInLiveContainer
        defer { isInLiveContainer = original }

        isInLiveContainer = (true, nil, false)
        #expect(RuntimeEnvironment.isLiveContainer)
        #expect(RuntimeEnvironment.label == "LiveContainer")

        isInLiveContainer = (false, nil, false)
        #expect(!RuntimeEnvironment.isLiveContainer)
        #expect(RuntimeEnvironment.label == "native")
    }

    // MARK: - enableJIT() LiveContainer gating

    /// The actual bug report this turn is built around: MeloNX must not
    /// attempt JITStreamerEB/TrollStore/StikJIT/builtInStikJIT on top of
    /// a JIT hand-off LiveContainer+StikDebug already completed.
    @Test func enableJITSkipsAllInternalMethodsInLiveContainer() {
        let original = isInLiveContainer
        defer { isInLiveContainer = original }
        isInLiveContainer = (true, nil, false)

        JITCoordinator.shared.resetAttempts()
        LaunchGameHandler().enableJIT()

        let attemptedMethods = Set(JITCoordinator.shared.methodAttempts.map { $0.name })
        #expect(!attemptedMethods.contains("JITStreamerEB"))
        #expect(!attemptedMethods.contains("TrollStore"))
        #expect(!attemptedMethods.contains("StikJIT"))
        #expect(!attemptedMethods.contains("builtInStikJIT"))

        #expect(JITCoordinator.shared.diagnosticsLog.contains { $0.contains("[LCJIT] detected LiveContainer") })
        #expect(JITCoordinator.shared.diagnosticsLog.contains { $0.contains("[JIT] internal acquisition skipped") })
    }

    /// Native (non-LiveContainer) must still take the real acquisition
    /// path - this is a regression guard for the LiveContainer branch
    /// added above, not a new behavior.
    @Test func enableJITTakesNativePathWhenNotInLiveContainer() {
        let original = isInLiveContainer
        defer { isInLiveContainer = original }
        isInLiveContainer = (false, nil, false)

        JITCoordinator.shared.resetAttempts()
        LaunchGameHandler().enableJIT()

        // The internal acquisition chain runs inside an async Task, so its
        // completion isn't deterministic here - this line is logged
        // synchronously, right before that Task is scheduled, and only on
        // the native path.
        #expect(JITCoordinator.shared.diagnosticsLog.contains { $0.contains("[JIT] enabled methods") })
    }

    // MARK: - JITCoordinator: definitive failure cancels polling immediately

    @Test func failImmediatelyStopsPollingAndResolvesNow() {
        JITCoordinator.shared.cancel()
        JITCoordinator.shared.resetAttempts()

        var result: Bool?
        _ = JITCoordinator.shared.waitForJIT(maxAttempts: 0, interval: 0.05) { success in
            result = success
        }
        #expect(JITCoordinator.shared.isPolling)

        JITCoordinator.shared.failImmediately(reason: "definitive failure")

        #expect(!JITCoordinator.shared.isPolling)
        #expect(result == false)
        #expect(JITCoordinator.shared.lastFailureReason == "definitive failure")
    }

    /// A generic "timed out" must never clobber a specific reason a
    /// caller already recorded earlier in the same cycle.
    @Test func recordFailureDoesNotOverwriteFirstReason() {
        JITCoordinator.shared.resetAttempts()
        JITCoordinator.shared.recordFailure("first real reason")
        JITCoordinator.shared.recordFailure("second generic reason")
        #expect(JITCoordinator.shared.lastFailureReason == "first real reason")
    }

    @Test func beginAcquisitionCycleClearsFailureReasonForNextAttempt() {
        JITCoordinator.shared.recordFailure("stale reason from a previous cycle")
        #expect(JITCoordinator.shared.lastFailureReason != nil)

        JITCoordinator.shared.beginAcquisitionCycle()
        #expect(JITCoordinator.shared.lastFailureReason == nil)
    }

    // MARK: - BootDiagnostics

    @Test func bootDiagnosticsTracksLastStage() {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("stage one", result: "ok")
        #expect(BootDiagnostics.shared.lastStage == "stage one")
    }

    @Test func bootDiagnosticsAppliesKnownStageFields() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("swapchain created")
        BootDiagnostics.shared.log("first GPU command submitted")
        BootDiagnostics.shared.log("first present completed")
        BootDiagnostics.shared.log("ran-first-frame")

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(BootDiagnostics.shared.swapchainCreated)
        #expect(BootDiagnostics.shared.firstSubmit)
        #expect(BootDiagnostics.shared.firstPresent)
        #expect(BootDiagnostics.shared.firstFrame)
    }

    @Test func bootDiagnosticsFailRecordsStageAndReason() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.fail(stage: "initialize_dualmapped", reason: "returned false")

        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(BootDiagnostics.shared.failureStage == "initialize_dualmapped")
        #expect(BootDiagnostics.shared.failureReason == "returned false")
    }

    @Test func bootDiagnosticsReportIncludesKeyFields() {
        BootDiagnostics.shared.beginBoot()
        let report = BootDiagnostics.shared.buildReport()
        #expect(report.contains("[GAME BOOT DIAGNOSTICS]"))
        #expect(report.contains("environment ="))
        #expect(report.contains("swapchainCreated ="))
        #expect(report.contains("STAGES:"))
    }

    @Test func bootDiagnosticsBeginBootResetsTransitoryState() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("swapchain created")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.swapchainCreated)

        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!BootDiagnostics.shared.swapchainCreated)
        #expect(BootDiagnostics.shared.stages.isEmpty)
    }

    // MARK: - LogCapture multi-subscriber fix

    /// Real bug this guards against: LogCapture used to hand out ONE
    /// shared AsyncStream continuation - two simultaneous consumers (e.g.
    /// two LogView instances, or LogView plus BootDiagnostics) would race
    /// to "steal" each line from each other instead of both seeing it.
    @Test func logCaptureBroadcastsToMultipleIndependentSubscribers() async throws {
        var receivedByFirst: [String] = []
        var receivedBySecond: [String] = []

        let firstTask = Task {
            for await line in LogCapture.shared.logs {
                receivedByFirst.append(line)
                if receivedByFirst.count >= 1 { break }
            }
        }
        let secondTask = Task {
            for await line in LogCapture.shared.logs {
                receivedBySecond.append(line)
                if receivedBySecond.count >= 1 { break }
            }
        }

        // Give both subscriptions time to register before anything is printed.
        try await Task.sleep(nanoseconds: 100_000_000)
        print("[BOOT] logCapture broadcast test line")
        try await Task.sleep(nanoseconds: 300_000_000)

        firstTask.cancel()
        secondTask.cancel()

        #expect(!receivedByFirst.isEmpty)
        #expect(!receivedBySecond.isEmpty)
    }

    // MARK: - BootEventPayloadParser (the deterministic C#->Swift bridge's decoding)

    @Test func parsesPlainStageWithNoValue() {
        let parsed = BootEventPayloadParser.parse("managed entry reached")
        #expect(parsed == .stage(name: "managed entry reached", value: nil))
    }

    @Test func parsesStageWithValue() {
        let parsed = BootEventPayloadParser.parse("physical device count|2")
        #expect(parsed == .stage(name: "physical device count", value: "2"))
    }

    @Test func parsesFailurePayload() {
        let parsed = BootEventPayloadParser.parse("FAIL|VulkanRenderer.SetupContext|System.Exception: boom\n   at Foo.Bar()")
        #expect(parsed == .failure(stage: "VulkanRenderer.SetupContext", reason: "System.Exception: boom\n   at Foo.Bar()"))
    }

    @Test func parsesFailurePayloadWithNoReasonSeparator() {
        // Malformed/truncated payload - must not crash, falls back to a
        // named "unknown" stage rather than losing the data entirely.
        let parsed = BootEventPayloadParser.parse("FAIL|justastring")
        #expect(parsed == .failure(stage: "unknown", reason: "justastring"))
    }

    @Test func stageValueCanItselfContainPipes() {
        // A reason/value can legitimately contain further "|" (e.g. a
        // stack trace with multiple frames) - only the FIRST separator
        // after the stage name must be treated as the boundary.
        let parsed = BootEventPayloadParser.parse("vkCreateSwapchainKHR|VK_ERROR_SURFACE_LOST_KHR|extra|detail")
        #expect(parsed == .stage(name: "vkCreateSwapchainKHR", value: "VK_ERROR_SURFACE_LOST_KHR|extra|detail"))
    }

    // MARK: - BootDiagnostics watchdog-panel field classification

    @Test func managedStagesSetManagedThreadAliveAndLastManagedStage() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("game load begin")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.managedThreadAlive)
        #expect(BootDiagnostics.shared.lastManagedStage == "game load begin")
    }

    @Test func rendererStagesSetLastRendererStage() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("swapchain creation begin")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.lastRendererStage == "swapchain creation begin")
    }

    @Test func surfaceAndSwapchainSuccessStagesSetTheirFlags() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("surface creation success")
        BootDiagnostics.shared.log("swapchain creation success")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.surfaceCreated)
        #expect(BootDiagnostics.shared.swapchainCreated)
    }

    @Test func metalViewStageSetsMetalViewAlive() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("MetalView.createView begin")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.metalViewAlive)
    }

    // MARK: - Swapchain -> acquire -> submit -> present trace (diagnóstico real #3)

    /// Real bug this guards against: a previous round logged
    /// "swapchain creation success" unconditionally reaching the report,
    /// but the actual device trace showed swapchainCreated=false even
    /// though MoltenVK's own driver log proved vkCreateSwapchainKHR had
    /// really succeeded - the transport (plain Console.WriteLine from a
    /// lower-level project) was unreliable, not the logic. This test only
    /// guards the Swift-side logic: a bare "swapchain creation begin" or
    /// "vkCreateSwapchainKHR" result event must NOT mark success by itself.
    @Test func swapchainOnlyMarksTrueAfterSuccessEvent() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("swapchain creation begin")
        BootDiagnostics.shared.log("vkCreateSwapchainKHR", result: "Success")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!BootDiagnostics.shared.swapchainCreated)

        BootDiagnostics.shared.log("swapchain creation success", result: "handle=123,extent=1320x743,imageCount=3")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.swapchainCreated)
        #expect(BootDiagnostics.shared.swapchainHandle == "123")
        #expect(BootDiagnostics.shared.swapchainImageCount == 3)
    }

    /// firstSubmit must reflect a REAL vkQueueSubmit success, not merely
    /// entering the method that calls it - the exact bug the previous
    /// round's "first GPU command submitted" breadcrumb had (it fired on
    /// Device.WaitFifo() returning true, a managed-level FIFO concept).
    @Test func submitOnlyMarksTrueAfterRealSuccess() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("queueSubmit begin")
        BootDiagnostics.shared.log("queueSubmit result", result: "ErrorDeviceLost")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!BootDiagnostics.shared.firstSubmit)
        #expect(BootDiagnostics.shared.lastSubmitResult == "ErrorDeviceLost")

        BootDiagnostics.shared.log("queueSubmit result", result: "Success")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.firstSubmit)
        #expect(BootDiagnostics.shared.lastSubmitResult == "Success")
    }

    /// firstPresent accepts both Success and SuboptimalKHR (frame still
    /// presented, swapchain just scheduled for recreation) but nothing else.
    @Test func presentMarksTrueOnSuccessOrSuboptimalButNotOtherResults() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("queuePresent result", result: "ErrorOutOfDateKhr")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!BootDiagnostics.shared.firstPresent)

        BootDiagnostics.shared.log("queuePresent result", result: "SuboptimalKhr")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.firstPresent)
        #expect(BootDiagnostics.shared.lastPresentResult == "SuboptimalKhr")
    }

    /// firstFrame must only be trusted when the engine's "ran-first-frame"
    /// signal is corroborated by a real successful present - otherwise it's
    /// a logged anomaly, not a silently-accepted success.
    @Test func ranFirstFrameOnlySetsFirstFrameWhenPresentAlreadySucceeded() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("ran-first-frame")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!BootDiagnostics.shared.firstFrame)

        BootDiagnostics.shared.log("queuePresent result", result: "Success")
        BootDiagnostics.shared.log("ran-first-frame")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.firstFrame)
    }

    /// The watchdog's whole purpose: distinguish "render thread alive" from
    /// "render thread alive AND actually progressing" - the last Vulkan-
    /// level milestone and its timestamp must be retained for exactly that.
    @Test func renderActivityTimestampAdvancesOnRealProgressEvents() async throws {
        BootDiagnostics.shared.beginBoot()
        #expect(BootDiagnostics.shared.secondsSinceLastRenderProgress() == nil)

        BootDiagnostics.shared.log("acquire result", result: "Success")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.lastRenderLoopStage == "acquire result")
        let elapsed = BootDiagnostics.shared.secondsSinceLastRenderProgress()
        #expect(elapsed != nil && elapsed! < 2.0)
    }

    @Test func acquireResultAccumulatesCountAndLastResult() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("acquire begin")
        BootDiagnostics.shared.log("acquire result", result: "NotReady")
        BootDiagnostics.shared.log("acquire result", result: "Success")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.acquireAttempted)
        #expect(BootDiagnostics.shared.acquireAttemptCount == 2)
        #expect(BootDiagnostics.shared.lastAcquireResult == "Success")
        #expect(BootDiagnostics.shared.firstAcquireSucceeded)
    }

    @Test func lastVulkanResultIsSetOnlyByRealVkResultCarryingStages() async throws {
        BootDiagnostics.shared.beginBoot()
        // Stage names that do NOT carry a VkResult must not clobber it.
        BootDiagnostics.shared.log("render loop entered")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(BootDiagnostics.shared.lastVulkanResult == nil)

        BootDiagnostics.shared.log("vkCreateSwapchainKHR", result: "Success")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(BootDiagnostics.shared.lastVulkanResult == "Success")
    }

    /// beginBoot() must clear every new field from this round too, or a
    /// retry attempt would start with stale success/failure state.
    @Test func beginBootResetsSwapchainTraceFields() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("swapchain creation success", result: "handle=1,extent=1x1,imageCount=2")
        BootDiagnostics.shared.log("acquire result", result: "Success")
        BootDiagnostics.shared.log("command buffer begin")
        BootDiagnostics.shared.log("queueSubmit result", result: "Success")
        BootDiagnostics.shared.log("queuePresent result", result: "Success")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.swapchainCreated)

        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!BootDiagnostics.shared.swapchainCreated)
        #expect(BootDiagnostics.shared.swapchainImageCount == nil)
        #expect(BootDiagnostics.shared.swapchainHandle == nil)
        #expect(!BootDiagnostics.shared.acquireAttempted)
        #expect(BootDiagnostics.shared.acquireAttemptCount == 0)
        #expect(!BootDiagnostics.shared.firstAcquireSucceeded)
        #expect(BootDiagnostics.shared.lastAcquireResult == nil)
        #expect(!BootDiagnostics.shared.commandBufferStarted)
        #expect(!BootDiagnostics.shared.commandBufferRecorded)
        #expect(BootDiagnostics.shared.lastSubmitResult == nil)
        #expect(BootDiagnostics.shared.lastPresentResult == nil)
        #expect(!BootDiagnostics.shared.renderLoopEntered)
        #expect(BootDiagnostics.shared.renderLoopIterations == 0)
        #expect(BootDiagnostics.shared.lastRenderLoopStage == nil)
        #expect(BootDiagnostics.shared.secondsSinceLastRenderProgress() == nil)
    }

    // MARK: - GPU.MainThread setup trace (diagnóstico real #4: GPU renderer initialized -> primer acquire)

    /// These events live between "GPU renderer initialized" and the first
    /// render-loop iteration, on a thread ("GPU.MainThread") distinct from
    /// the one that logs "render loop entered" - they must still register
    /// as real render progress, or the watchdog's lastRenderLoopStage would
    /// go stale exactly during the window this round is trying to observe.
    @Test func gpuMainThreadSetupEventsCountAsRenderProgress() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("GPU.MainThread lambda entered")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.lastRenderLoopStage == "GPU.MainThread lambda entered")

        BootDiagnostics.shared.log("InitializeShaderCache: before HostInitalized wait")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.lastRenderLoopStage == "InitializeShaderCache: before HostInitalized wait")
    }

    /// The exact symptom this round investigates: renderLoopEntered=true
    /// (set from the unrelated "render loop entered" event logged on the
    /// GUI.RenderLoop thread) must not be confused with the GPU.MainThread
    /// loop actually iterating - renderLoopIterations only advances from
    /// real "render loop heartbeat" events emitted inside the while loop.
    @Test func renderLoopIterationsOnlyAdvancesFromRealHeartbeats() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("render loop entered")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.renderLoopEntered)
        #expect(BootDiagnostics.shared.renderLoopIterations == 0)

        BootDiagnostics.shared.log("render loop heartbeat", result: "3")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.renderLoopIterations == 3)
    }
}
