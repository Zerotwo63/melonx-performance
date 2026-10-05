//
//  MemoryGuard.swift
//  MeloNX
//

import Foundation

/// Watches real OS-level memory pressure via GCD's memory pressure
/// source — the signal that actually precedes a jetsam kill — which this
/// project has no observer for at all: grepping the whole codebase found
/// zero references to didReceiveMemoryWarning, memoryPressure, or
/// makeMemoryPressureSource before this file. MemoryUsageMonitor polls
/// this process's own phys_footprint on a timer, which is a different,
/// weaker signal (your own footprint rising doesn't necessarily mean the
/// system is actually under pressure, and the system can come under
/// pressure from other processes regardless of your own footprint).
///
/// Deliberately passive: exposes the current pressure level and when it
/// last changed, and takes no action of its own. Ryujinx.clearShaderCache()
/// — the one existing cache-clearing hook — is a destructive,
/// currently user-confirmed-only action (deletes cached shader
/// compilation from disk); wiring it to fire automatically and silently
/// from a background guard would be a real, surprising behavior change
/// this fork hasn't been asked for. Reacting to pressure (clearing
/// caches, lowering resolution scale, etc.) is a separate, later step.
@MainActor
final class MemoryGuard: ObservableObject {
    enum PressureLevel: String {
        case normal
        case warning
        case critical
    }

    static let shared = MemoryGuard()

    @Published private(set) var currentLevel: PressureLevel = .normal
    @Published private(set) var lastTransitionAt: Date?

    private var source: DispatchSourceMemoryPressure?

    private init() {}

    func start() {
        guard source == nil else { return }

        let pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressureSource.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            self.handle(source.data)
        }
        pressureSource.resume()
        source = pressureSource
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func handle(_ event: DispatchSource.MemoryPressureEvent) {
        let level: PressureLevel
        if event.contains(.critical) {
            level = .critical
        } else if event.contains(.warning) {
            level = .warning
        } else {
            level = .normal
        }

        guard level != currentLevel else { return }

        currentLevel = level
        lastTransitionAt = Date()
        print("[memory-guard] pressure level changed to \(level.rawValue)")
    }
}
