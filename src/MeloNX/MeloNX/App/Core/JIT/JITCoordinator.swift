//
//  JITCoordinator.swift
//  MeloNX
//

import Foundation

/// Single source of truth for "is JIT ready yet". Replaces the two
/// independent wait implementations that used to exist:
/// - JITPopover's uncapped Timer (no timeout, never cancelled on
///   disappear, so it kept calling isJITEnabled() — and through it,
///   RyujinxBridge.initialize_dualmapped() — forever if the popover went
///   away for any reason other than JIT becoming ready).
/// - ContentView.checkJITAndRunGame()'s capped recursive asyncAfter retry,
///   which checked isJITEnabled() immediately before ever waiting —
///   waitForJIT() does the same immediate check below so migrating that
///   call site doesn't add a spurious 0.5s delay when JIT is already on.

/// One attempt at one JIT method, as seen by LaunchGameHandler.enableJIT().
/// Exists so JITDiagnosticsView can show a real per-method history instead
/// of just the final state - every field here is something the user
/// explicitly asked to see broken out per method, not a convenience
/// summary.
struct JITMethodAttempt: Identifiable {
    let id = UUID()
    let name: String
    var detected: Bool
    var enabled: Bool
    var attempted: Bool = false
    let startedAt: Date
    var endedAt: Date?
    var result: String = "pending"
    var error: String?
    var underlyingError: String?
    var errnoValue: Int32?
    var timedOut: Bool = false
    var pairingStatus: String?
    var connectionStatus: String?

    var elapsed: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    enum ReadinessState: Equatable {
        case idle
        case waiting(attempt: Int)
        case ready
        case timedOut
    }

    @Published private(set) var state: ReadinessState = .idle
    @Published private(set) var diagnosticsLog: [String] = []
    @Published private(set) var methodAttempts: [JITMethodAttempt] = []
    @Published private(set) var lastFailureReason: String?
    @Published private(set) var retryCount: Int = 0

    private var pollTimer: Timer?
    private var pendingCompletions: [(Bool) -> Void] = []

    private init() {}

    var isPolling: Bool { pollTimer != nil }

    /// On-screen, visible-without-Xcode log — same reasoning as SetupView's
    /// diagLog: print() alone is useless to someone testing on a real
    /// iPhone with no Mac.
    func logDiag(_ message: String) {
        print(message)
        diagnosticsLog.append(message)
        if diagnosticsLog.count > 300 {
            diagnosticsLog.removeFirst(diagnosticsLog.count - 300)
        }
    }

    /// Clears transitory per-cycle state (the attempt history and last
    /// failure reason) but never touches diagnosticsLog - the log must
    /// accumulate across an entire session, including retries.
    func resetAttempts() {
        methodAttempts.removeAll()
        lastFailureReason = nil
    }

    func beginAcquisitionCycle() {
        resetAttempts()
        logDiag("[JIT] coordinator started")
    }

    /// Retry keeps the prior log intact and marks a clear boundary in it,
    /// rather than starting over - the whole point is comparing attempt #1
    /// against #2 in one continuous transcript.
    func beginRetry() {
        retryCount += 1
        logDiag("")
        logDiag("===== JIT RETRY #\(retryCount) =====")
    }

    @discardableResult
    func beginAttempt(_ name: String, detected: Bool, enabled: Bool) -> UUID {
        let attempt = JITMethodAttempt(name: name, detected: detected, enabled: enabled, startedAt: Date())
        methodAttempts.append(attempt)
        logDiag("[JIT] method discovered: \(name)")
        logDiag("[JIT] enabled = \(enabled)")
        return attempt.id
    }

    func updateAttempt(_ id: UUID, _ mutate: (inout JITMethodAttempt) -> Void) {
        guard let index = methodAttempts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&methodAttempts[index])
    }

    func finishAttempt(_ id: UUID) {
        updateAttempt(id) { attempt in
            attempt.endedAt = Date()
        }
        guard let attempt = methodAttempts.first(where: { $0.id == id }) else { return }
        if let error = attempt.error {
            logDiag("[JIT] \(attempt.name) failed: \(error)")
        } else {
            logDiag("[JIT] \(attempt.name) \(attempt.result)")
        }
    }

    func recordFailure(_ reason: String) {
        lastFailureReason = reason
        logDiag("[JIT] final result = FAILED")
        logDiag("[JIT] failure reason = \(reason)")
        logDiag("[JIT] acquisition failed")
    }

    /// Starts a single poll loop for JIT readiness, or — if one is already
    /// running (e.g. checkJITAndRunGame's resume-after-relaunch wait is
    /// still in flight when JITPopover also calls in) — queues this
    /// completion to fire alongside the in-flight loop's result instead of
    /// dropping it. Every caller's completion is guaranteed to fire
    /// exactly once; `trigger` only runs for the caller that actually
    /// starts the loop, since a wait is already underway for the rest.
    ///
    /// - maxAttempts: 0 means no cap (matches JITPopover's current
    ///   behavior); pass a positive value to time out, like
    ///   checkJITAndRunGame's 6-attempt cap. If callers disagree, whichever
    ///   call started the loop wins — a joining caller gets the result of
    ///   that loop, not its own cap.
    @discardableResult
    func waitForJIT(
        trigger: (() -> Void)? = nil,
        maxAttempts: Int = 0,
        interval: TimeInterval = 0.5,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isPolling else {
            pendingCompletions.append(completion)
            return false
        }

        trigger?()

        if isJITEnabled() {
            state = .ready
            logDiag("[JIT] acquired")
            completion(true)
            return true
        }

        var attempt = 0
        state = .waiting(attempt: attempt)
        logDiag("[JIT] waiting")

        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            attempt += 1
            self.logDiag("[JIT] waiting attempt = \(attempt)")
            self.logDiag("[JIT] waiting attempt \(attempt)")

            if isJITEnabled() {
                self.stopPolling()
                self.state = .ready
                self.logDiag("[JIT] acquired")
                self.resolve(true, primary: completion)
                return
            }

            if maxAttempts > 0 && attempt >= maxAttempts {
                self.stopPolling()
                self.state = .timedOut
                self.logDiag("[JIT] timed out")
                self.logDiag("[JIT] timeout")
                self.recordFailure("JITCoordinator timed out after \(attempt) attempts")
                self.resolve(false, primary: completion)
                return
            }

            self.state = .waiting(attempt: attempt)
        }

        return true
    }

    private func resolve(_ success: Bool, primary: (Bool) -> Void) {
        primary(success)
        let queued = pendingCompletions
        pendingCompletions.removeAll()
        queued.forEach { $0(success) }
    }

    /// Cancels any in-flight poll loop. Callers that start a wait (e.g. a
    /// view's onAppear) must call this from onDisappear — this is the fix
    /// for JITPopover's current leak, where dismissing the popover any way
    /// other than JIT succeeding leaves its Timer running indefinitely.
    ///
    /// No-ops if another caller has joined the current loop (has a
    /// completion queued in `pendingCompletions`) — tearing the timer down
    /// out from under them would strand their completion forever, since it
    /// only ever fires from inside that timer's closure. Their loop keeps
    /// running until it resolves on its own (success or their cap).
    func cancel() {
        guard pendingCompletions.isEmpty else { return }
        stopPolling()
        state = .idle
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
