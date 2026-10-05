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
/// - Adjusts resolution scale (resscale) by one step, down to a floor,
///   via InGameSettingsManager.shared.saveSettings() — the one path
///   that already knows how to push live via
///   RyujinxBridge.updateSettingsExternal(argv:). Not duplicating
///   buildCommandLineArgs/updateSettingsExternal call sites.
/// - Whenever that throttle lands below 1.0x, also switches to FSR
///   (scalingFilter), restoring both resscale and scalingFilter
///   together once pressure clears. This only works because
///   ApplyDynamicSettings (src/Ryujinx.Headless.SDL2/Program.cs) now
///   actually propagates ScalingFilter on a live update — before that
///   fix, forcing FSR here would have silently done nothing until the
///   next relaunch. scalingFilterLevel (sharpening) is left as
///   whatever the user already has configured — this only flips the
///   Bilinear/FSR choice, never touches sharpening intensity.
/// - Never reaches PerGameSettingsManager (the *separate* class that
///   actually writes to disk) — confirmed by reading its real
///   implementation, not assumed. Both resscale and scalingFilter are
///   restored to the user's own baseline once pressure clears, and
///   this never leaves a trace in the user's saved per-game settings
///   file.
/// - Off by default: unlike MemoryGuard/ThermalGovernor (passive, zero
///   visible effect), this one visibly changes rendering quality
///   without a specific per-instance confirmation, so it's opt-in.
@MainActor
final class AutoPerformanceManager: ObservableObject {
    static let shared = AutoPerformanceManager()

    @Published private(set) var isActive = false
    @Published private(set) var isThrottling = false
    @Published private(set) var isUsingAutoFSR = false

    private let step = 0.25
    private let minimumScale = 0.5

    private var baselineScale: Double?
    private var baselineScalingFilter: ScalingFilter?
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

        // Below 1.0x, FSR's upscale recovers some of the sharpness a
        // plain bilinear stretch would lose — switch to it, matching
        // the policy as given: "cuando AutoPerformanceManager reduzca
        // la resolución por debajo de 1.0x ... usa FSR". Sharpening
        // level (scalingFilterLevel) is left untouched — this only
        // flips the Bilinear/FSR choice.
        if throttled < 1.0, config.scalingFilter != .fsr {
            baselineScalingFilter = config.scalingFilter
            config.scalingFilter = .fsr
            isUsingAutoFSR = true
        }

        InGameSettingsManager.shared.config[titleId] = config
        InGameSettingsManager.shared.saveSettings()

        isThrottling = true
        print("[auto-performance] throttling resolution scale to \(throttled)\(isUsingAutoFSR ? " (FSR)" : "")")
    }

    private func restoreBaselineIfNeeded() {
        defer {
            isThrottling = false
            isUsingAutoFSR = false
            baselineScale = nil
            baselineScalingFilter = nil
        }

        guard isThrottling, let baselineScale, let (titleId, config) = currentGameAndConfig() else { return }

        config.resscale = baselineScale
        if let baselineScalingFilter {
            config.scalingFilter = baselineScalingFilter
        }

        InGameSettingsManager.shared.config[titleId] = config
        InGameSettingsManager.shared.saveSettings()

        print("[auto-performance] restored resolution scale to \(baselineScale)\(baselineScalingFilter != nil ? " and scaling filter" : "")")
    }
}
