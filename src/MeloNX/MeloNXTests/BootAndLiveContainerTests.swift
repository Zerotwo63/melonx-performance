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

    // MARK: - Guest CPU / NvServices / GPU-FIFO producer trace (diagnóstico real #5)
    //
    // These tests only cover the diagnostic plumbing (event parsing and
    // field classification) - they never fabricate real GPU/guest work,
    // never set firstFrame artificially, and never touch the watchdog
    // timeout itself. The goal of this round is to find the real blockage,
    // not to make a boot "look" successful.

    @Test func guestMainThreadFieldsTrackKProcessAndKThreadEvents() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("KProcess.Start: main thread created")
        BootDiagnostics.shared.log("KProcess.Start: main thread Start result", result: "Success")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.guestMainThreadCreated)
        #expect(BootDiagnostics.shared.guestMainThreadStarted)
        #expect(!BootDiagnostics.shared.guestMainThreadAlive)

        BootDiagnostics.shared.log("KThread.ThreadStart: guest Context.Execute begin", result: "threadCount=1")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.guestMainThreadAlive)
        #expect(BootDiagnostics.shared.guestThreadCount == 1)
        #expect(BootDiagnostics.shared.guestExecutionHeartbeats == 1)
        #expect(BootDiagnostics.shared.lastGuestStage == "KThread.ThreadStart: guest Context.Execute begin")
    }

    /// A "Start result" that is NOT "Success" must not be reported as
    /// started - the field name promises a real kernel-level outcome, not
    /// just "the event fired".
    @Test func guestMainThreadStartedIsFalseOnNonSuccessResult() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("KProcess.Start: main thread Start result", result: "InvalidState")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!BootDiagnostics.shared.guestMainThreadStarted)
    }

    @Test func fifoProducerFieldsTrackSubmitGpfifoAndQueueCounters() async throws {
        BootDiagnostics.shared.beginBoot()
        #expect(!BootDiagnostics.shared.fifoProducerAlive)

        BootDiagnostics.shared.log("SubmitGpfifo ioctl received", result: "count=3")
        BootDiagnostics.shared.log("GPU-FIFO total queued", result: "7")
        BootDiagnostics.shared.log("GPU-FIFO total consumed", result: "5")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.fifoProducerAlive)
        #expect(BootDiagnostics.shared.gpfifoSubmissions == 3)
        #expect(BootDiagnostics.shared.fifoCommandsQueued == 7)
        #expect(BootDiagnostics.shared.fifoCommandsConsumed == 5)
    }

    @Test func fifoWaitForCommandsParsesAllThreeCounters() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("GPU-FIFO WaitForCommands", result: "result=False,waitCalls=2400,waitTrue=0,waitFalse=2400")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.fifoWaitCalls == 2400)
        #expect(BootDiagnostics.shared.fifoWaitTrue == 0)
        #expect(BootDiagnostics.shared.fifoWaitFalse == 2400)
    }

    @Test func gpuContextAndChannelCreationFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("GpuContext created")
        BootDiagnostics.shared.log("GPU channel created", result: "2")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.gpuContextCreated)
        #expect(BootDiagnostics.shared.gpuChannelsCreated == 2)
    }

    /// Each layer (guest, GPU producer, Nv, translator) keeps its own
    /// "last stage" independently - one layer's event must not clobber
    /// another's, or the watchdog would misattribute where things stalled.
    @Test func lastStagePerLayerStaysIndependent() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("KThread.ThreadStart: guest Context.Execute begin", result: "threadCount=1")
        BootDiagnostics.shared.log("NvHostChannelDeviceFile created")
        BootDiagnostics.shared.log("GPU-FIFO total queued", result: "1")
        BootDiagnostics.shared.log("ARMeilleure.Translator.Execute entered", result: "threadCount=1")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.lastGuestStage == "KThread.ThreadStart: guest Context.Execute begin")
        #expect(BootDiagnostics.shared.lastNvStage == "NvHostChannelDeviceFile created")
        #expect(BootDiagnostics.shared.lastGpuProducerStage == "GPU-FIFO total queued")
        #expect(BootDiagnostics.shared.lastTranslatorStage == "ARMeilleure.Translator.Execute entered")
    }

    @Test func gpuThreadAliveTracksMainThreadLambdaEnteredOnly() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("render loop entered")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.renderThreadAlive)
        #expect(!BootDiagnostics.shared.gpuThreadAlive)

        BootDiagnostics.shared.log("GPU.MainThread lambda entered")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.gpuThreadAlive)
    }

    @Test func beginBootResetsGuestAndFifoProducerFields() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("KProcess.Start: main thread created")
        BootDiagnostics.shared.log("SubmitGpfifo ioctl received", result: "count=1")
        BootDiagnostics.shared.log("GPU channel created", result: "1")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.guestMainThreadCreated)

        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!BootDiagnostics.shared.guestMainThreadCreated)
        #expect(!BootDiagnostics.shared.guestMainThreadStarted)
        #expect(!BootDiagnostics.shared.guestMainThreadAlive)
        #expect(BootDiagnostics.shared.guestThreadCount == 0)
        #expect(BootDiagnostics.shared.guestExecutionHeartbeats == 0)
        #expect(BootDiagnostics.shared.translatedFunctionsCreated == 0)
        #expect(BootDiagnostics.shared.translatedFunctionsExecuted == 0)
        #expect(BootDiagnostics.shared.lastGuestStage == nil)
        #expect(!BootDiagnostics.shared.gpuContextCreated)
        #expect(BootDiagnostics.shared.gpuChannelsCreated == 0)
        #expect(BootDiagnostics.shared.gpfifoSubmissions == 0)
        #expect(BootDiagnostics.shared.fifoCommandsQueued == 0)
        #expect(BootDiagnostics.shared.fifoCommandsConsumed == 0)
        #expect(BootDiagnostics.shared.fifoWaitCalls == 0)
        #expect(BootDiagnostics.shared.fifoWaitTrue == 0)
        #expect(BootDiagnostics.shared.fifoWaitFalse == 0)
        #expect(BootDiagnostics.shared.lastGpuProducerStage == nil)
        #expect(BootDiagnostics.shared.lastNvStage == nil)
        #expect(BootDiagnostics.shared.lastTranslatorStage == nil)
        #expect(!BootDiagnostics.shared.gpuThreadAlive)
        #expect(!BootDiagnostics.shared.fifoProducerAlive)
    }

    @Test func buildReportIncludesNewGuestAndGpuProducerFields() {
        BootDiagnostics.shared.beginBoot()
        let report = BootDiagnostics.shared.buildReport()

        #expect(report.contains("GUEST:"))
        #expect(report.contains("guestMainThreadCreated ="))
        #expect(report.contains("GPU PRODUCER:"))
        #expect(report.contains("gpfifoSubmissions ="))
        #expect(report.contains("THREAD SNAPSHOT:"))
        #expect(report.contains("fifoProducerAlive ="))
    }

    // MARK: - LightningJit translator trace (diagnóstico real #6)
    //
    // ArmProcessContextFactory picks Ryujinx.Cpu.LightningJit.Translator as
    // the active backend on this build (arm64 host + MemoryManagerMode.
    // HostMapped/HostMappedUnsafe) - NOT ARMeilleure.Translation.Translator,
    // which the previous round's instrumentation targeted. These tests
    // only cover the diagnostic plumbing - no real GPU/guest work is ever
    // fabricated here.

    @Test func contextExecuteEnteredTracksRealGuestPc() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.Translator.Execute entered", result: "pc=0x7FFE1000,threadId=3")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.contextExecuteEntered)
        #expect(BootDiagnostics.shared.translatorExecuteEntered)
        #expect(BootDiagnostics.shared.firstGuestPc == "0x7FFE1000")
        #expect(BootDiagnostics.shared.lastGuestPc == "0x7FFE1000")
    }

    /// firstGuestPc must never move once set, even if later lookups report
    /// a different address - it specifically answers "where did the guest
    /// start", not "where is it now" (that's lastGuestPc/lastTranslatorAddress).
    @Test func firstGuestPcNeverChangesAfterFirstSet() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.Translator.Execute entered", result: "pc=0x1000,threadId=1")
        BootDiagnostics.shared.log("LightningJit translate lookup begin", result: "pc=0x2000,count=1")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.firstGuestPc == "0x1000")
        #expect(BootDiagnostics.shared.lastGuestPc == "0x2000")
    }

    /// Real cumulative counters from C# (sent as "count=N" in the payload)
    /// must be used directly - never approximated from how many log events
    /// Swift happened to receive, since the C# side gates logging after the
    /// first 10 occurrences while the real counter keeps incrementing.
    @Test func translationCountersUseRealCumulativeValueNotEventCount() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit translate begin", result: "pc=0x1000,count=37")
        BootDiagnostics.shared.log("LightningJit translate compiled", result: "pc=0x1000,hostCodeLength=64,count=12")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.translationAttempts == 37)
        #expect(BootDiagnostics.shared.translatedFunctionsCreated == 12)
    }

    /// The NOP fallback (an existing, pre-this-round behavior that silently
    /// swaps a failed translation for a synthetic NOP+RET) must be counted
    /// SEPARATELY from real compiled functions - it must never inflate
    /// translatedFunctionsCreated, or a stream of silent failures would look
    /// identical to real progress.
    @Test func nopFallbackDoesNotInflateTranslatedFunctionsCreated() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit translate NOP fallback", result: "pc=0x1000,exceptionType=System.OutOfMemoryException,count=5")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.nopFallbackCount == 5)
        #expect(BootDiagnostics.shared.translatedFunctionsCreated == 0)
    }

    @Test func jitMemFieldsTrackAllocationsAndAddresses() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JITMEM allocate", result: "size=256")
        BootDiagnostics.shared.log("JITMEM RW ptr", result: "0xAAAA0000")
        BootDiagnostics.shared.log("JITMEM RX ptr", result: "0xBBBB0000")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.jitCodeAllocations == 1)
        #expect(BootDiagnostics.shared.jitBytesGenerated == 256)
        #expect(BootDiagnostics.shared.jitRwAddress == "0xAAAA0000")
        #expect(BootDiagnostics.shared.jitRxAddress == "0xBBBB0000")
    }

    /// hostFunctionCallReturned/translatedFunctionsExecuted can only become
    /// true/positive once the native dispatcher comes back for a SECOND
    /// lookup - a single mapped function proves nothing was executed yet,
    /// since there is no managed hook at the actual jump-to-host-code site.
    @Test func hostFunctionCallReturnedRequiresASecondLookup() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit translate lookup begin", result: "pc=0x1000,count=1")
        BootDiagnostics.shared.log("LightningJit translate mapped", result: "pc=0x1000,funcPtr=0xCCCC0000")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.hostFunctionCallAttempted)
        #expect(!BootDiagnostics.shared.hostFunctionCallReturned)
        #expect(BootDiagnostics.shared.translatedFunctionsExecuted == 0)

        BootDiagnostics.shared.log("LightningJit translate lookup begin", result: "pc=0x1004,count=2")
        BootDiagnostics.shared.log("LightningJit translate mapped", result: "pc=0x1004,funcPtr=0xCCCC0040")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.hostFunctionCallReturned)
        #expect(BootDiagnostics.shared.translatedFunctionsExecuted == 1)
    }

    @Test func beginBootResetsLightningJitTranslatorFields() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.Translator.Execute entered", result: "pc=0x1000,threadId=1")
        BootDiagnostics.shared.log("JITMEM allocate", result: "size=128")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.contextExecuteEntered)

        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!BootDiagnostics.shared.contextExecuteEntered)
        #expect(!BootDiagnostics.shared.contextExecuteReturned)
        #expect(!BootDiagnostics.shared.translatorExecuteEntered)
        #expect(BootDiagnostics.shared.translatorLookupAttempts == 0)
        #expect(BootDiagnostics.shared.translationAttempts == 0)
        #expect(BootDiagnostics.shared.nopFallbackCount == 0)
        #expect(BootDiagnostics.shared.jitCodeAllocations == 0)
        #expect(BootDiagnostics.shared.jitBytesGenerated == 0)
        #expect(BootDiagnostics.shared.firstGuestPc == nil)
        #expect(BootDiagnostics.shared.lastGuestPc == nil)
        #expect(BootDiagnostics.shared.lastTranslatorAddress == nil)
        #expect(BootDiagnostics.shared.jitRwAddress == nil)
        #expect(BootDiagnostics.shared.jitRxAddress == nil)
        #expect(!BootDiagnostics.shared.hostFunctionCallAttempted)
        #expect(!BootDiagnostics.shared.hostFunctionCallReturned)
    }

    // MARK: - Watchdog state-based classification (diagnóstico real #6)
    //
    // The watchdog used to always say "timeout waiting for swapchain/first
    // frame" no matter how far boot actually got. These tests lock in the
    // real pipeline-walk behavior - especially the exact scenario this
    // round's real device trace showed (swapchain created, guest alive,
    // zero translated functions, zero GPU submissions).

    @Test func classifiesAsJitWhenJitNeverVerified() async throws {
        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage == "JIT")
    }

    @Test func classifiesAsSwapchainWhenSwapchainNeverCreated() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JIT verification result", result: "true")
        BootDiagnostics.shared.log("initialize_dualmapped result", result: "true")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage == "renderer / swapchain")
    }

    @Test func classifiesAsGuestCpuStartupWhenGuestNeverAlive() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JIT verification result", result: "true")
        BootDiagnostics.shared.log("initialize_dualmapped result", result: "true")
        BootDiagnostics.shared.log("swapchain creation success", result: "handle=1,extent=1x1,imageCount=1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage == "guest CPU startup")
    }

    /// The exact real-device scenario this round is built around:
    /// swapchainCreated=true, guestMainThreadAlive=true,
    /// translatedFunctionsCreated=0, gpfifoSubmissions=0.
    @Test func classifiesAsTranslatorStartupMatchingRealDeviceScenario() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JIT verification result", result: "true")
        BootDiagnostics.shared.log("initialize_dualmapped result", result: "true")
        BootDiagnostics.shared.log("swapchain creation success", result: "handle=1,extent=1x1,imageCount=1")
        BootDiagnostics.shared.log("KThread.ThreadStart: guest Context.Execute begin", result: "threadCount=1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, reason) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage == "guest CPU / translator startup")
        #expect(reason.contains("no translated function was created or executed"))
    }

    @Test func classifiesAsGpuProducerWhenTranslatingButNotSubmitting() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JIT verification result", result: "true")
        BootDiagnostics.shared.log("initialize_dualmapped result", result: "true")
        BootDiagnostics.shared.log("swapchain creation success", result: "handle=1,extent=1x1,imageCount=1")
        BootDiagnostics.shared.log("KThread.ThreadStart: guest Context.Execute begin", result: "threadCount=1")
        BootDiagnostics.shared.log("LightningJit translate compiled", result: "pc=0x1000,hostCodeLength=64,count=1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage == "guest CPU / GPU producer")
    }

    @Test func classifiesAsAcquireWhenGpuWorkSubmittedButNeverAcquired() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JIT verification result", result: "true")
        BootDiagnostics.shared.log("initialize_dualmapped result", result: "true")
        BootDiagnostics.shared.log("swapchain creation success", result: "handle=1,extent=1x1,imageCount=1")
        BootDiagnostics.shared.log("KThread.ThreadStart: guest Context.Execute begin", result: "threadCount=1")
        BootDiagnostics.shared.log("LightningJit translate compiled", result: "pc=0x1000,hostCodeLength=64,count=1")
        BootDiagnostics.shared.log("SubmitGpfifo ioctl received", result: "count=1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage == "renderer / acquire")
    }

    // MARK: - LightningJit DispatchLoop/DispatchStub/SameMapProbe trace (diagnóstico real #7)
    //
    // These tests only cover the diagnostic plumbing (event parsing, field
    // classification, and the refined A-F watchdog classification) - they
    // never fabricate real GPU/guest/translator work.

    private func reachTranslatorStartupBoundary() {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JIT verification result", result: "true")
        BootDiagnostics.shared.log("initialize_dualmapped result", result: "true")
        BootDiagnostics.shared.log("swapchain creation success", result: "handle=1,extent=1x1,imageCount=1")
        BootDiagnostics.shared.log("KThread.ThreadStart: guest Context.Execute begin", result: "threadCount=1")
    }

    @Test func dispatchLoopResolveAndCallFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.DispatchLoop resolve end")
        BootDiagnostics.shared.log("LightningJit.DispatchLoop pointer", result: "0x7000008000")
        BootDiagnostics.shared.log("LightningJit.DispatchLoop CALL BEGIN", result: "pc=0x8500000")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchLoopResolved)
        #expect(BootDiagnostics.shared.dispatchLoopPointer == "0x7000008000")
        #expect(BootDiagnostics.shared.dispatchLoopCallBegan)
        #expect(!BootDiagnostics.shared.dispatchLoopCallReturned)

        BootDiagnostics.shared.log("LightningJit.DispatchLoop CALL RETURNED", result: "pc=0x8500000")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.dispatchLoopCallReturned)
    }

    @Test func nativeStageMarkersDeriveEnteredFlags() async throws {
        BootDiagnostics.shared.beginBoot()
        #expect(!BootDiagnostics.shared.dispatchStubEntered)
        #expect(!BootDiagnostics.shared.slowDispatchStubEntered)

        BootDiagnostics.shared.log("LightningJit.dispatchLoopNativeStage", result: "3")
        BootDiagnostics.shared.log("LightningJit.dispatchStubStage", result: "10")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchLoopNativeStage == 3)
        #expect(BootDiagnostics.shared.dispatchStubStage == 10)
        #expect(BootDiagnostics.shared.dispatchStubEntered)
        #expect(!BootDiagnostics.shared.slowDispatchStubEntered)
    }

    @Test func sameMapProbeFieldsTrackPassAndFail() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.SameMapProbe mapped", result: "rw=0xAAA0,rx=0xBBB0")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe call begin")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe call returned", result: "result=0x12345678")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe PASS")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchProbeRwAddress == "0xAAA0")
        #expect(BootDiagnostics.shared.dispatchProbeRxAddress == "0xBBB0")
        #expect(BootDiagnostics.shared.dispatchProbeCallAttempted)
        #expect(BootDiagnostics.shared.dispatchProbeReturned)
        #expect(BootDiagnostics.shared.dispatchProbeReturnValue == "0x12345678")
        #expect(BootDiagnostics.shared.dispatchProbePassed == true)

        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.SameMapProbe FAIL")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.dispatchProbePassed == false)
    }

    @Test func nativeGetFunctionAddressFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("NativeInterface.GetFunctionAddress entered", result: "framePointer=0x1,address=0x8500000,calls=1")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.nativeGetFunctionAddressEntered)
        #expect(BootDiagnostics.shared.nativeGetFunctionAddressCalls == 1)
        #expect(BootDiagnostics.shared.nativeGetFunctionAddressAddress == "0x8500000")
        #expect(BootDiagnostics.shared.nativeGetFunctionAddressFramePointer == "0x1")
    }

    @Test func functionTableFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.FunctionTable info", result: "base=0x100,mask=0x1FFFFFFFF,fill=0x7000000000,levelCount=5")
        BootDiagnostics.shared.log("LightningJit.FunctionTable stubs", result: "dispatchStub=0x7000004000,slowDispatchStub=0x7000000000")
        BootDiagnostics.shared.log("LightningJit.FunctionTable lookup", result: "address=0x8500000,inRange=true")
        BootDiagnostics.shared.log("LightningJit.FunctionTable level indices", result: "level0=4,level1=0")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.functionTableBase == "0x100")
        #expect(BootDiagnostics.shared.functionTableLevelCount == 5)
        #expect(BootDiagnostics.shared.functionTableDispatchStubPtr == "0x7000004000")
        #expect(BootDiagnostics.shared.functionTableAddressInRange == true)
        #expect(BootDiagnostics.shared.functionTableLevelIndices == "level0=4,level1=0")
    }

    @Test func jitMemByteVerificationFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("JITMEM bytes written (RW)", result: "AABBCCDD")
        BootDiagnostics.shared.log("JITMEM bytes read back (RX alias)", result: "AABBCCDD")
        BootDiagnostics.shared.log("JITMEM RW/RX bytes match", result: "true")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.jitMemBytesWritten == "AABBCCDD")
        #expect(BootDiagnostics.shared.jitMemBytesReadBack == "AABBCCDD")
        #expect(BootDiagnostics.shared.jitMemBytesMatch == true)
    }

    @Test func directDispatchProbeFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        #expect(!BootDiagnostics.shared.directDispatchProbeAttempted)

        BootDiagnostics.shared.log("LightningJit.DirectDispatchProbe begin", result: "framePointer=0x0,address=0x8500000")
        BootDiagnostics.shared.log("LightningJit.DirectDispatchProbe result", result: "hostFuncPtr=0x7000010000")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.directDispatchProbeAttempted)
        #expect(BootDiagnostics.shared.directDispatchProbeResult == "0x7000010000")
    }

    // MARK: - Watchdog scenarios A-F (diagnóstico real #7)

    @Test func classifiesScenarioAWhenSameMapProbeFails() async throws {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit.SameMapProbe FAIL")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("Scenario A"))
    }

    @Test func classifiesScenarioBWhenCallBeganButNativeStageNeverAdvances() async throws {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit.DispatchLoop CALL BEGIN", result: "pc=0x8500000")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("Scenario B"))
    }

    @Test func classifiesScenarioCWhenDispatchLoopRunningButNotYetAtDispatchStub() async throws {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit.DispatchLoop CALL BEGIN", result: "pc=0x8500000")
        BootDiagnostics.shared.log("LightningJit.dispatchLoopNativeStage", result: "3")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("Scenario C"))
    }

    @Test func classifiesScenarioDWhenDispatchStubEnteredButNoGetFunctionAddress() async throws {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit.DispatchLoop CALL BEGIN", result: "pc=0x8500000")
        BootDiagnostics.shared.log("LightningJit.dispatchLoopNativeStage", result: "4")
        BootDiagnostics.shared.log("LightningJit.dispatchStubStage", result: "12")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("Scenario D"))
    }

    @Test func classifiesScenarioEWhenGetFunctionAddressEnteredButNoTranslateAttempt() async throws {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit.DispatchLoop CALL BEGIN", result: "pc=0x8500000")
        BootDiagnostics.shared.log("LightningJit.dispatchLoopNativeStage", result: "4")
        BootDiagnostics.shared.log("LightningJit.dispatchStubStage", result: "14")
        BootDiagnostics.shared.log("NativeInterface.GetFunctionAddress entered", result: "framePointer=0x1,address=0x8500000,calls=1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("Scenario E"))
    }

    @Test func classifiesScenarioFWhenFunctionCreatedButNeverExecuted() async throws {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit translate compiled", result: "pc=0x8500000,hostCodeLength=64,count=1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("Scenario F"))
    }

    @Test func beginBootResetsAllFase7Fields() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("LightningJit.DispatchLoop resolve end")
        BootDiagnostics.shared.log("LightningJit.dispatchLoopNativeStage", result: "5")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe PASS")
        BootDiagnostics.shared.log("NativeInterface.GetFunctionAddress entered", result: "framePointer=0x1,address=0x1,calls=1")
        BootDiagnostics.shared.log("LightningJit.FunctionTable info", result: "base=0x1,mask=0x1,fill=0x1,levelCount=5")
        BootDiagnostics.shared.log("LightningJit.DirectDispatchProbe begin")
        BootDiagnostics.shared.log("JITMEM RW/RX bytes match", result: "true")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.dispatchLoopResolved)

        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(!BootDiagnostics.shared.dispatchLoopResolved)
        #expect(BootDiagnostics.shared.dispatchLoopPointer == nil)
        #expect(!BootDiagnostics.shared.dispatchLoopCallBegan)
        #expect(!BootDiagnostics.shared.dispatchLoopCallReturned)
        #expect(BootDiagnostics.shared.dispatchLoopNativeStage == 0)
        #expect(BootDiagnostics.shared.dispatchStubStage == 0)
        #expect(BootDiagnostics.shared.slowDispatchStubStage == 0)
        #expect(BootDiagnostics.shared.dispatchProbePassed == nil)
        #expect(!BootDiagnostics.shared.nativeGetFunctionAddressEntered)
        #expect(BootDiagnostics.shared.nativeGetFunctionAddressCalls == 0)
        #expect(BootDiagnostics.shared.functionTableBase == nil)
        #expect(!BootDiagnostics.shared.directDispatchProbeAttempted)
        #expect(BootDiagnostics.shared.jitMemBytesMatch == nil)
    }

    @Test func buildReportIncludesFase7Sections() {
        BootDiagnostics.shared.beginBoot()
        let report = BootDiagnostics.shared.buildReport()

        #expect(report.contains("DISPATCH"))
        #expect(report.contains("NATIVE STAGE MARKERS"))
        #expect(report.contains("SAME-MAP PROBE"))
        #expect(report.contains("FUNCTION TABLE"))
        #expect(report.contains("DIRECT-DISPATCH PROBE"))
        #expect(report.contains("JITMEM BYTE VERIFICATION"))
    }

    // MARK: - Dual-map probe hang investigation (diagnóstico real #8, FASES 8A-8G)
    //
    // These tests only cover the diagnostic plumbing (event parsing and the
    // A1-A7 sub-classification) - they never fabricate real execution
    // results, and the probe's own hang/crash behavior is never altered.

    private func enterProbeHungState() {
        reachTranslatorStartupBoundary()
        BootDiagnostics.shared.log("LightningJit.SameMapProbe mapped", result: "rw=0x7040004000,rx=0x7000004000")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe call begin")
        // dispatchProbeReturned stays false - the call never returns, the
        // exact real-device scenario this round investigates.
    }

    @Test func fase8aFieldsTrackRwRxBytesAndCoherence() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("dispatchProbeBytesRx", result: "00CF8A52C0035FD6")
        BootDiagnostics.shared.log("dispatchProbeRwRxBytesMatch", result: "true")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe coherence pattern A", result: "wrote=AAAAAAAA,readRx=AAAAAAAA,match=true")
        BootDiagnostics.shared.log("LightningJit.SameMapProbe coherence pattern B", result: "wrote=55555555,readRx=55555555,match=true")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchProbeBytesRx == "00CF8A52C0035FD6")
        #expect(BootDiagnostics.shared.dispatchProbeRwRxBytesMatch == true)
        #expect(BootDiagnostics.shared.dispatchProbeCoherencePatternAMatch == true)
        #expect(BootDiagnostics.shared.dispatchProbeCoherencePatternBMatch == true)
    }

    @Test func fase8bProtectionFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("NativeMemoryDiagnostics.QueryProtection RW", result: "regionBase=0x7040004000,regionSize=0x4000,current=READ,WRITE,max=READ,WRITE,EXECUTE")
        BootDiagnostics.shared.log("NativeMemoryDiagnostics.QueryProtection RX", result: "regionBase=0x7000004000,regionSize=0x4000,current=READ,EXECUTE,max=READ,EXECUTE")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchProbeRwCurrentProtection == "READ,WRITE")
        #expect(BootDiagnostics.shared.dispatchProbeRxCurrentProtection == "READ,EXECUTE")
        #expect(BootDiagnostics.shared.dispatchProbeRxMaxProtection == "READ,EXECUTE")
    }

    @Test func fase8cCacheSyncFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("dispatchProbeDcacheFlushRwAttempted", result: "true")
        BootDiagnostics.shared.log("dispatchProbeIcacheInvalidateRwAttempted", result: "true")
        BootDiagnostics.shared.log("dispatchProbeIcacheInvalidateRxAttempted", result: "true")
        BootDiagnostics.shared.log("dispatchProbeCacheSyncCompleted", result: "true")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchProbeDcacheFlushRwAttempted)
        #expect(BootDiagnostics.shared.dispatchProbeIcacheInvalidateRwAttempted)
        #expect(BootDiagnostics.shared.dispatchProbeIcacheInvalidateRxAttempted)
        #expect(BootDiagnostics.shared.dispatchProbeCacheSyncCompleted == true)
    }

    @Test func fase8dNativeControlFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("nativeControlPointer", result: "0x1234")
        BootDiagnostics.shared.log("nativeControlCallAttempted", result: "true")
        BootDiagnostics.shared.log("nativeControlReturned", result: "true")
        BootDiagnostics.shared.log("nativeControlReturnValue", result: "1234")
        BootDiagnostics.shared.log("nativeControlPassed", result: "true")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.nativeControlCallAttempted)
        #expect(BootDiagnostics.shared.nativeControlReturned)
        #expect(BootDiagnostics.shared.nativeControlReturnValue == "1234")
        #expect(BootDiagnostics.shared.nativeControlPassed == true)
    }

    @Test func fase8eSingleMapFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("singleMapRwAddress", result: "0xAAAA")
        BootDiagnostics.shared.log("singleMapExecAddress", result: "0xAAAA")
        BootDiagnostics.shared.log("singleMapCallAttempted", result: "true")
        BootDiagnostics.shared.log("singleMapReturned", result: "true")
        BootDiagnostics.shared.log("singleMapReturnValue", result: "0x12345678")
        BootDiagnostics.shared.log("singleMapPassed", result: "true")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.singleMapRwAddress == "0xAAAA")
        #expect(BootDiagnostics.shared.singleMapReturned)
        #expect(BootDiagnostics.shared.singleMapPassed == true)
    }

    @Test func fase8fArchitectureFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("processArchitecture", result: "Arm64")
        BootDiagnostics.shared.log("isArm64e", result: "false")
        BootDiagnostics.shared.log("pointerAuthenticationRelevant", result: "false")

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.processArchitecture == "Arm64")
        #expect(BootDiagnostics.shared.isArm64e == "false")
    }

    @Test func fase8gStageMarkerFieldsTrack() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("sameMapNativeEntryStage", result: "1")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(BootDiagnostics.shared.sameMapNativeEntryStage == 1)
        #expect(BootDiagnostics.shared.sameMapNativeBeforeRetStage == 0)

        BootDiagnostics.shared.log("sameMapNativeBeforeRetStage", result: "2")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(BootDiagnostics.shared.sameMapNativeBeforeRetStage == 2)
    }

    // MARK: - A1-A7 classification

    @Test func classifiesA1WhenRwRxBytesDiffer() async throws {
        enterProbeHungState()
        BootDiagnostics.shared.log("dispatchProbeRwRxBytesMatch", result: "false")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("A1"))
    }

    @Test func classifiesA2WhenRxLacksExecute() async throws {
        enterProbeHungState()
        BootDiagnostics.shared.log("dispatchProbeRwRxBytesMatch", result: "true")
        BootDiagnostics.shared.log("NativeMemoryDiagnostics.QueryProtection RX", result: "regionBase=0x1,regionSize=0x4000,current=READ,WRITE,max=READ,WRITE")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("A2"))
    }

    @Test func classifiesA4WhenNativeControlFails() async throws {
        enterProbeHungState()
        BootDiagnostics.shared.log("dispatchProbeRwRxBytesMatch", result: "true")
        BootDiagnostics.shared.log("NativeMemoryDiagnostics.QueryProtection RX", result: "regionBase=0x1,regionSize=0x4000,current=READ,EXECUTE,max=READ,EXECUTE")
        BootDiagnostics.shared.log("nativeControlPassed", result: "false")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("A4"))
    }

    @Test func classifiesA5WhenSingleMapPassesButDualMapHangs() async throws {
        enterProbeHungState()
        BootDiagnostics.shared.log("dispatchProbeRwRxBytesMatch", result: "true")
        BootDiagnostics.shared.log("NativeMemoryDiagnostics.QueryProtection RX", result: "regionBase=0x1,regionSize=0x4000,current=READ,EXECUTE,max=READ,EXECUTE")
        BootDiagnostics.shared.log("nativeControlPassed", result: "true")
        BootDiagnostics.shared.log("singleMapPassed", result: "true")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("A5"))
    }

    @Test func classifiesA6WhenEnteredButNeverReachedRet() async throws {
        enterProbeHungState()
        BootDiagnostics.shared.log("dispatchProbeRwRxBytesMatch", result: "true")
        BootDiagnostics.shared.log("NativeMemoryDiagnostics.QueryProtection RX", result: "regionBase=0x1,regionSize=0x4000,current=READ,EXECUTE,max=READ,EXECUTE")
        BootDiagnostics.shared.log("nativeControlPassed", result: "true")
        BootDiagnostics.shared.log("singleMapPassed", result: "false")
        BootDiagnostics.shared.log("sameMapNativeEntryStage", result: "1")
        try await Task.sleep(nanoseconds: 150_000_000)

        let (stage, _) = BootDiagnostics.shared.classifyWatchdogFailure()
        #expect(stage.hasPrefix("A6"))
    }

    @Test func beginBootResetsFase8Fields() async throws {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("dispatchProbeBytesRx", result: "AA")
        BootDiagnostics.shared.log("nativeControlPassed", result: "true")
        BootDiagnostics.shared.log("singleMapPassed", result: "true")
        BootDiagnostics.shared.log("isArm64e", result: "true")
        BootDiagnostics.shared.log("sameMapNativeEntryStage", result: "1")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(BootDiagnostics.shared.dispatchProbeBytesRx == "AA")

        BootDiagnostics.shared.beginBoot()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(BootDiagnostics.shared.dispatchProbeBytesRx == nil)
        #expect(BootDiagnostics.shared.dispatchProbeRwRxBytesMatch == nil)
        #expect(BootDiagnostics.shared.nativeControlPassed == nil)
        #expect(BootDiagnostics.shared.singleMapPassed == nil)
        #expect(BootDiagnostics.shared.isArm64e == nil)
        #expect(BootDiagnostics.shared.sameMapNativeEntryStage == 0)
        #expect(BootDiagnostics.shared.sameMapNativeBeforeRetStage == 0)
    }

    @Test func buildReportIncludesFase8Section() {
        BootDiagnostics.shared.beginBoot()
        let report = BootDiagnostics.shared.buildReport()

        #expect(report.contains("DUAL-MAP PROBE HANG INVESTIGATION"))
        #expect(report.contains("nativeControlPassed ="))
        #expect(report.contains("singleMapPassed ="))
        #expect(report.contains("sameMapNativeEntryStage ="))
    }
}
