//
//  ThermalGovernor.swift
//  MeloNX
//

import Foundation

/// Watches the real OS-level thermal state (ProcessInfo.thermalState /
/// thermalStateDidChangeNotification) — the actual signal iOS gives for
/// "this device is heating up," the thermal analogue of MemoryGuard's
/// memory pressure source. Grepping the whole project found no existing
/// reference to thermalState/ThermalState/thermalStateDidChange before
/// this file.
///
/// Deliberately passive, same as MemoryGuard: logs transitions and
/// exposes the current state, takes no action of its own. Throttling
/// anything (resolution scale, frame pacing, etc.) in response to heat
/// is a real behavior change this fork hasn't been asked for — a later,
/// separate step once there's an actual governing action to wire up,
/// not invented here just because the name suggests one.
@MainActor
final class ThermalGovernor: ObservableObject {
    static let shared = ThermalGovernor()

    @Published private(set) var currentState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lastTransitionAt: Date?

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleChange()
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func handleChange() {
        let state = ProcessInfo.processInfo.thermalState
        guard state != currentState else { return }

        currentState = state
        lastTransitionAt = Date()
        print("[thermal-governor] thermal state changed to \(describe(state))")
    }

    private func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
