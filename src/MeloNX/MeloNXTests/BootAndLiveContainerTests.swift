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
}
