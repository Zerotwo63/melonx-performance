//
//  AutoPerformanceManager.swift
//  MeloNX
//

import Foundation
import Combine

/// Consumes the passive signals ThermalGovernor/MemoryGuard already
/// expose and actually acts on them — unlike those two (deliberately
/// passive by design), this is the one meant to take action, so it does.
/// It starts them itself (both guard against double-starting already)
/// rather than requiring the user to also have their own toggles on —
/// AutoPerformanceManager treats them as its own dependencies.
///
/// Scope, deliberately conservative for a first version:
/// - Reacts to thermal .serious/.critical (adaptive-quality apps
///   commonly start at .serious rather than waiting for .critical,
///   which usually means things are already bad) or memory .critical
///   only (not .warning, which is common enough under ordinary load
///   that reacting to it would make this trigger-happy).
/// - Only adjusts resolution scale (resscale) by one step, down to a
///   floor — the one setting InGameSettingsManager already knows how
///   to push live via RyujinxBridge.updateSettingsExternal(argv:), the
///   exact path the (currently unused anywhere else) in-game settings
///   mechanism already provides. Not inventing a new mid-session
///   settings-push mechanism, and not duplicating
///   buildCommandLineArgs/updateSettingsExternal call sites — reusing
///   InGameSettingsManager.shared.saveSettings() as-is.
/// - Never reaches PerGameSettingsManager (the *separate* class that
///   actually writes to disk) — confirmed by reading its real
///   implementation, not assumed. The throttle is restored to the
///   user's own baseline once pressure clears, and this never leaves a
///   trace in the user's saved per-game settings file.
/// - Off by default: unlike MemoryGuard/ThermalGovernor (passive, zero
///   visible effect), this one visibly changes rendering quality
///   without a specific per-instance confirmation, so it's opt-in.
@MainActor
final class AutoPerformanceManager: ObservableObject {
    static let shared = AutoPerformanceManager()

    @Published private(set) var isActive = false
    @Published private(set) var isThrottling = false

    private let step = 0.25
    private let minimumScale = 0.5

    private var baselineScale: Double?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        guard !isActive else { return }
        isActive = true

        ThermalGovernor.shared.start()
        MemoryGuard.shared.start()

        ThermalGovernor.shared.$currentState
            .sink { [weak self] state in
                self?.reevaluate(thermal: state, memory: MemoryGuard.shared.currentLevel)
            }
            .store(in: &cancellables)

        MemoryGuard.shared.$currentLevel
            .sink { [weak self] level in
                self?.reevaluate(thermal: ThermalGovernor.shared.currentState, memory: level)
            }
            .store(in: &cancellables)
    }

    func stop() {
        isActive = false
        cancellables.removeAll()
        restoreBaselineIfNeeded()
    }

    private func reevaluate(thermal: ProcessInfo.ThermalState, memory: MemoryGuard.PressureLevel) {
        let shouldThrottle = thermal == .serious || thermal == .critical || memory == .critical

        if shouldThrottle, !isThrottling {
            beginThrottling()
        } else if !shouldThrottle, isThrottling {
            restoreBaselineIfNeeded()
        }
    }

    private func currentGameAndConfig() -> (titleId: String, config: Ryujinx.Arguments)? {
        guard let game = Ryujinx.shared.games.first(where: { $0.fileURL == URL(string: Ryujinx.shared.config?.gamepath ?? "") }) else {
            return nil
        }
        guard let config = InGameSettingsManager.shared.config[game.titleId] ?? Ryujinx.shared.config else {
            return nil
        }
        return (game.titleId, config)
    }

    private func beginThrottling() {
        guard let (titleId, config) = currentGameAndConfig() else { return }

        let throttled = max(minimumScale, config.resscale - step)
        guard throttled != config.resscale else { return }

        baselineScale = config.resscale
        config.resscale = throttled
        InGameSettingsManager.shared.config[titleId] = config
        InGameSettingsManager.shared.saveSettings()

        isThrottling = true
        print("[auto-performance] throttling resolution scale to \(throttled)")
    }

    private func restoreBaselineIfNeeded() {
        defer {
            isThrottling = false
            baselineScale = nil
        }

        guard isThrottling, let baselineScale, let (titleId, config) = currentGameAndConfig() else { return }

        config.resscale = baselineScale
        InGameSettingsManager.shared.config[titleId] = config
        InGameSettingsManager.shared.saveSettings()

        print("[auto-performance] restored resolution scale to \(baselineScale)")
    }
}
