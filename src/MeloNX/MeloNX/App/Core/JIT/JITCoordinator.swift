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
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    enum ReadinessState: Equatable {
        case idle
        case waiting(attempt: Int)
        case ready
        case timedOut
    }

    @Published private(set) var state: ReadinessState = .idle

    private var pollTimer: Timer?
    private var pendingCompletions: [(Bool) -> Void] = []

    private init() {}

    var isPolling: Bool { pollTimer != nil }

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
            completion(true)
            return true
        }

        var attempt = 0
        state = .waiting(attempt: attempt)

        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            attempt += 1

            if isJITEnabled() {
                self.stopPolling()
                self.state = .ready
                self.resolve(true, primary: completion)
                return
            }

            if maxAttempts > 0 && attempt >= maxAttempts {
                self.stopPolling()
                self.state = .timedOut
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
