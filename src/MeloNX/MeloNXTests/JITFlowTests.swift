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
}
