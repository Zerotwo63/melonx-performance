//
//  JITCoordinator.swift
//  MeloNX
//

import Foundation

/// Single source of truth for "is JIT ready yet", replacing the two
/// independent wait implementations that exist today:
/// - JITPopover's uncapped Timer (no timeout, never cancelled on
///   disappear, so it keeps calling isJITEnabled() — and through it,
///   RyujinxBridge.initialize_dualmapped() — forever if the popover goes
///   away for any reason other than JIT becoming ready).
/// - ContentView.checkJITAndRunGame()'s capped recursive asyncAfter retry.
///
/// Not wired into either call site yet — this is the additive foundation;
/// swapping those two call sites over is a separate, later commit.
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

    private init() {}

    var isPolling: Bool { pollTimer != nil }

    /// Starts a single poll loop for JIT readiness. No-ops (returns false)
    /// if a loop is already running, so concurrent callers can't stack
    /// multiple timers the way JITPopover and checkJITAndRunGame can today.
    ///
    /// - maxAttempts: 0 means no cap (matches JITPopover's current
    ///   behavior); pass a positive value to time out, like
    ///   checkJITAndRunGame's 6-attempt cap.
    @discardableResult
    func waitForJIT(
        trigger: (() -> Void)? = nil,
        maxAttempts: Int = 0,
        interval: TimeInterval = 0.5,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isPolling else { return false }

        trigger?()

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
                completion(true)
                return
            }

            if maxAttempts > 0 && attempt >= maxAttempts {
                self.stopPolling()
                self.state = .timedOut
                completion(false)
                return
            }

            self.state = .waiting(attempt: attempt)
        }

        return true
    }

    /// Cancels any in-flight poll loop. Callers that start a wait (e.g. a
    /// view's onAppear) must call this from onDisappear — this is the fix
    /// for JITPopover's current leak, where dismissing the popover any way
    /// other than JIT succeeding leaves its Timer running indefinitely.
    func cancel() {
        stopPolling()
        state = .idle
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
