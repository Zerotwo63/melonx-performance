//
//  JITFlowTests.swift
//  MeloNXTests
//

import Testing
@testable import MeloNX

/// Covers the pieces of the JIT activation flow that are actually
/// testable without a real device: JITStreamerEB's response decoding
/// (pure, no network), and JITCoordinator's dedup/cancel guarantees (the
/// exact behavior Stage 2 of this work was supposed to preserve, not
/// just re-describe in a doc comment).
///
/// `.serialized`: JITCoordinator is a singleton with shared mutable
/// state, same as the rest of this codebase's other `.shared` managers —
/// running these in parallel against each other would be genuinely
/// flaky, not just theoretically risky.
@Suite(.serialized)
struct JITFlowTests {
    @Test func attachResultDecodesSuccess() throws {
        let json = Data(#"{"success": true, "message": "attached"}"#.utf8)
        let result = try JSONDecoder().decode(JITStreamerEB.AttachResult.self, from: json)

        #expect(result.success)
        #expect(result.message == "attached")
    }

    @Test func attachResultDecodesFailure() throws {
        let json = Data(#"{"success": false, "message": "no pairing file"}"#.utf8)
        let result = try JSONDecoder().decode(JITStreamerEB.AttachResult.self, from: json)

        #expect(!result.success)
        #expect(result.message == "no pairing file")
    }

    @Test func waitForJITTimesOutWithoutALeakedTimer() async throws {
        JITCoordinator.shared.cancel()

        var triggered = false
        let started = JITCoordinator.shared.waitForJIT(
            trigger: { triggered = true },
            maxAttempts: 1,
            interval: 0.05
        ) { success in
            #expect(success == false)
        }

        #expect(started)
        #expect(triggered)

        // maxAttempts: 1 at a 0.05s interval resolves almost immediately;
        // give it real wall-clock time to finish rather than asserting
        // anything about internal timing.
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(!JITCoordinator.shared.isPolling)
    }

    @Test func secondCallerJoinsInsteadOfLosingItsCompletion() async throws {
        JITCoordinator.shared.cancel()

        var firstResult: Bool?
        var secondResult: Bool?

        let startedFirst = JITCoordinator.shared.waitForJIT(maxAttempts: 2, interval: 0.05) { success in
            firstResult = success
        }
        #expect(startedFirst)
        #expect(JITCoordinator.shared.isPolling)

        // A second caller arriving while the first is still polling must
        // not have its completion silently dropped — it should queue and
        // still fire once the in-flight loop resolves.
        let startedSecond = JITCoordinator.shared.waitForJIT { success in
            secondResult = success
        }
        #expect(!startedSecond)

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(firstResult == false)
        #expect(secondResult == false)
    }

    @Test func cancelDoesNotStrandAJoinedCaller() async throws {
        JITCoordinator.shared.cancel()

        var joinerResult: Bool?

        _ = JITCoordinator.shared.waitForJIT(maxAttempts: 2, interval: 0.05) { _ in }
        _ = JITCoordinator.shared.waitForJIT { success in
            joinerResult = success
        }

        // Simulates a view that joined an in-flight loop disappearing and
        // calling cancel() — it must not tear down the timer the other
        // caller (and this joiner) still depend on.
        JITCoordinator.shared.cancel()
        #expect(JITCoordinator.shared.isPolling)

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(joinerResult == false)
    }

    /// Bug 2 fix verification: JITPopover used to call waitForJIT with no
    /// cap at all (maxAttempts: 0, the default), so JITCoordinator could
    /// never reach .timedOut on its own — "stuck on Waiting for JIT
    /// forever" was not a flaky timeout, it was structurally guaranteed.
    /// This pins the exact state sequence a capped wait produces when
    /// isJITEnabled() never returns true, which is the real-world case
    /// whenever the underlying JIT mechanism silently fails.
    @Test func timeoutPathReachesTimedOutNotStuckForever() async throws {
        JITCoordinator.shared.cancel()

        var observedStates: [JITCoordinator.ReadinessState] = []
        var result: Bool?

        _ = JITCoordinator.shared.waitForJIT(maxAttempts: 2, interval: 0.05) { success in
            observedStates.append(JITCoordinator.shared.state)
            result = success
        }

        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(result == false)
        #expect(JITCoordinator.shared.state == .timedOut)
        #expect(!JITCoordinator.shared.isPolling)
    }

    /// A caller retrying after a timeout (e.g. the popover's own Retry
    /// button) must get a brand new, independent poll — not find the
    /// coordinator wedged in .timedOut from the previous attempt.
    @Test func retryAfterTimeoutStartsAFreshPoll() async throws {
        JITCoordinator.shared.cancel()

        var firstResult: Bool?
        _ = JITCoordinator.shared.waitForJIT(maxAttempts: 1, interval: 0.05) { success in
            firstResult = success
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(firstResult == false)
        #expect(JITCoordinator.shared.state == .timedOut)

        var secondResult: Bool?
        let startedSecond = JITCoordinator.shared.waitForJIT(maxAttempts: 1, interval: 0.05) { success in
            secondResult = success
        }
        #expect(startedSecond)
        #expect(JITCoordinator.shared.isPolling)

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(secondResult == false)
    }

    /// Cancelling with no other caller joined must stop polling
    /// immediately and never fire the completion at all — distinct from
    /// cancelDoesNotStrandAJoinedCaller, which covers the opposite case.
    @Test func cancelWithNoJoinerStopsPollingAndNeverResolves() async throws {
        JITCoordinator.shared.cancel()

        var fired = false
        _ = JITCoordinator.shared.waitForJIT(maxAttempts: 0, interval: 0.05) { _ in
            fired = true
        }
        #expect(JITCoordinator.shared.isPolling)

        JITCoordinator.shared.cancel()
        #expect(!JITCoordinator.shared.isPolling)
        #expect(JITCoordinator.shared.state == .idle)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!fired)
    }

    /// Pure wire-format check for the Built-in StikJIT helper protocol —
    /// MeloNXBuiltInJIT.enableCurrentProcess() depends on this round-trip
    /// being exact, since MeloNXJITHelper (a separate extension target)
    /// keeps its own duplicate of this struct that must match byte-for-byte.
    @Test func helperRequestResponseRoundTrips() throws {
        let request = MeloNXJITHelperRequest(operation: .prepare, targetPID: 1234, pairingData: Data([0x01, 0x02]))
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MeloNXJITHelperRequest.self, from: encoded)

        #expect(decoded.operation == .prepare)
        #expect(decoded.targetPID == 1234)
        #expect(decoded.pairingData == Data([0x01, 0x02]))

        let response = MeloNXJITHelperRequest.Response(success: false, message: "no DDI cached", txmPresent: true)
        let encodedResponse = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(MeloNXJITHelperRequest.Response.self, from: encodedResponse)

        #expect(!decodedResponse.success)
        #expect(decodedResponse.message == "no DDI cached")
        #expect(decodedResponse.txmPresent == true)
    }

    // --- JIT diagnostics plumbing (new) ---

    @Test func beginAndFinishAttemptRecordsSuccess() {
        JITCoordinator.shared.resetAttempts()

        let id = JITCoordinator.shared.beginAttempt("TestMethod", detected: true, enabled: true)
        JITCoordinator.shared.updateAttempt(id) { attempt in
            attempt.attempted = true
            attempt.result = "success"
        }
        JITCoordinator.shared.finishAttempt(id)

        let attempt = JITCoordinator.shared.methodAttempts.first { $0.id == id }
        #expect(attempt?.name == "TestMethod")
        #expect(attempt?.detected == true)
        #expect(attempt?.enabled == true)
        #expect(attempt?.attempted == true)
        #expect(attempt?.result == "success")
        #expect(attempt?.error == nil)
        #expect((attempt?.elapsed ?? -1) >= 0)
    }

    @Test func finishAttemptRecordsError() {
        JITCoordinator.shared.resetAttempts()

        let id = JITCoordinator.shared.beginAttempt("TestMethod", detected: true, enabled: true)
        JITCoordinator.shared.updateAttempt(id) { attempt in
            attempt.result = "failed"
            attempt.error = "boom"
            attempt.errnoValue = 13
        }
        JITCoordinator.shared.finishAttempt(id)

        let attempt = JITCoordinator.shared.methodAttempts.first { $0.id == id }
        #expect(attempt?.result == "failed")
        #expect(attempt?.error == "boom")
        #expect(attempt?.errnoValue == 13)
    }

    @Test func resetAttemptsClearsHistoryAndFailureReason() {
        let id = JITCoordinator.shared.beginAttempt("TestMethod", detected: true, enabled: true)
        JITCoordinator.shared.updateAttempt(id) { attempt in
            attempt.result = "failed"
            attempt.error = "boom"
        }
        JITCoordinator.shared.finishAttempt(id)
        JITCoordinator.shared.recordFailure("overall failure")

        #expect(!JITCoordinator.shared.methodAttempts.isEmpty)
        #expect(JITCoordinator.shared.lastFailureReason != nil)

        JITCoordinator.shared.resetAttempts()

        #expect(JITCoordinator.shared.methodAttempts.isEmpty)
        #expect(JITCoordinator.shared.lastFailureReason == nil)
    }

    @Test func beginRetryIncrementsCountWithoutClearingLog() {
        JITCoordinator.shared.resetAttempts()
        let before = JITCoordinator.shared.retryCount
        let logCountBefore = JITCoordinator.shared.diagnosticsLog.count

        JITCoordinator.shared.beginRetry()

        #expect(JITCoordinator.shared.retryCount == before + 1)
        #expect(JITCoordinator.shared.diagnosticsLog.count > logCountBefore)
        #expect(JITCoordinator.shared.diagnosticsLog.last?.contains("JIT RETRY") == true)
    }

    /// JITStreamerEB is attempted unconditionally by LaunchGameHandler,
    /// regardless of any Settings toggle — this must always be listed,
    /// even with every fallback toggle off.
    @Test func enabledMethodNamesAlwaysListsInternalPath() {
        let names = JITDiagnostics.enabledMethodNames()
        #expect(names.contains { $0.contains("JITStreamerEB") })
    }

    @Test func methodCapabilitiesAlwaysListsAllFourMethods() {
        let capabilities = JITDiagnostics.methodCapabilities()
        #expect(capabilities.count == 4)
        #expect(capabilities.contains { $0.method.contains("JITStreamerEB") })
        #expect(capabilities.contains { $0.method.contains("TrollStore") })
        #expect(capabilities.contains { $0.method.contains("StikJIT") })
        #expect(capabilities.contains { $0.method.contains("Built-in StikJIT") })
    }

    @Test func probeExecutableMemoryNeverCrashesAndReportsSomething() {
        let probe = JITDiagnostics.probeExecutableMemory()
        #expect(probe.mmapSucceeded || !probe.errorDescription.isEmpty)
    }

    @Test func diagnosticsReportIsNeverEmpty() {
        let report = JITDiagnostics.buildReport()
        #expect(report.contains("[JIT DIAGNOSTICS]"))
        #expect(report.contains("ENTITLEMENTS:"))
        #expect(report.contains("CURRENT PROCESS:"))
        #expect(report.contains("METHOD DETECTION:"))
        #expect(report.contains("ATTEMPT ORDER:"))
        #expect(report.contains("FINAL:"))
    }
}
