//
//  BenchmarkManager.swift
//  MeloNX
//

import Foundation
import UIKit

/// Objective, structured performance measurement — the tool that makes a
/// claim like "FSR made this faster" checkable instead of anecdotal, per
/// this fork's own stated priority on objective measurement over
/// impressions.
///
/// FPS statistics reuse the exact signal source FPSMonitor already polls
/// (RyujinxBridge.currentFPS) rather than inventing a new timing
/// mechanism. Frame-pacing (interval jitter) reuses the same
/// CADisplayLink technique FramePacingMonitor uses, folded in here
/// directly so a single start()/stop() captures both, per the request
/// to extend BenchmarkManager rather than requiring two separately
/// coordinated tools.
///
/// `resolutionScale`/`activeScalingFilter`/`thermalState` are snapshots
/// of the live config/ThermalGovernor state read at `stop()` time, not
/// tracked as time series — correct for a short benchmark run where
/// these don't change mid-run under manual testing, but would need
/// revisiting if a run spans an AutoPerformanceManager-driven change.
///
/// No CPU/GPU frame time (in milliseconds) field exists here — see
/// PERFORMANCE_FORK.md's FSR investigation for why: the only
/// per-frame-time-like figure the native core exposes
/// (`PerformanceStatistics.GetGameFrameTime()`) is a pure derivation of
/// the same frame rate RyujinxBridge.currentFPS already reports
/// (`1000 / frameRate`), not an independent measurement, so adding it
/// would just duplicate the FPS figures already here under a different
/// name. Not simulating a number that doesn't actually exist.
@MainActor
final class BenchmarkManager: NSObject, ObservableObject {
    struct Result {
        let duration: TimeInterval
        let sampleCount: Int
        let averageFPS: Double
        let minFPS: Double
        let maxFPS: Double
        let fps1PercentLow: Double
        let averageMemory: UInt64
        let peakMemory: UInt64
        let worstFrameJitter: TimeInterval
        let resolutionScale: Double
        let activeScalingFilter: ScalingFilter
        let thermalState: ProcessInfo.ThermalState
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: Result?

    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var fpsSamples: [Double] = []
    private var memorySamples: [UInt64] = []

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval?
    private var frameIntervals: [TimeInterval] = []

    override init() {
        super.init()
    }

    func start() {
        guard !isRunning else { return }

        isRunning = true
        startedAt = Date()
        fpsSamples = []
        memorySamples = []
        frameIntervals = []
        lastFrameTimestamp = nil

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.fpsSamples.append(Double(RyujinxBridge.currentFPS))
                self.memorySamples.append(Self.currentMemoryFootprint())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    @discardableResult
    func stop() -> Result? {
        guard isRunning, let startedAt else { return nil }

        task?.cancel()
        task = nil
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
        self.startedAt = nil

        guard !fpsSamples.isEmpty else { return nil }

        let memoryCount = max(memorySamples.count, 1)
        let sortedFPS = fpsSamples.sorted()
        let onePercentCount = max(1, sortedFPS.count / 100)
        let fps1PercentLow = sortedFPS.prefix(onePercentCount).reduce(0, +) / Double(onePercentCount)

        let averageInterval = frameIntervals.isEmpty ? 0 : frameIntervals.reduce(0, +) / Double(frameIntervals.count)
        let worstJitter = frameIntervals.map { abs($0 - averageInterval) }.max() ?? 0

        let result = Result(
            duration: Date().timeIntervalSince(startedAt),
            sampleCount: fpsSamples.count,
            averageFPS: fpsSamples.reduce(0, +) / Double(fpsSamples.count),
            minFPS: fpsSamples.min() ?? 0,
            maxFPS: fpsSamples.max() ?? 0,
            fps1PercentLow: fps1PercentLow,
            averageMemory: memorySamples.reduce(0, +) / UInt64(memoryCount),
            peakMemory: memorySamples.max() ?? 0,
            worstFrameJitter: worstJitter,
            resolutionScale: Ryujinx.shared.config?.resscale ?? 0,
            activeScalingFilter: Ryujinx.shared.config?.scalingFilter ?? .bilinear,
            thermalState: ThermalGovernor.shared.currentState
        )

        lastResult = result
        return result
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let lastFrameTimestamp {
            frameIntervals.append(link.targetTimestamp - lastFrameTimestamp)
        }
        lastFrameTimestamp = link.targetTimestamp
    }

    /// Same task_info/phys_footprint approach MemoryUsageMonitor already
    /// uses for its own poll loop — duplicated rather than shared: that
    /// method is private to a different, unrelated class, and this
    /// needs its own sample on the same cadence as the FPS sample, not a
    /// second independent poll loop.
    private static func currentMemoryFootprint() -> UInt64 {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride) / 4

        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        return result == KERN_SUCCESS ? taskInfo.phys_footprint : 0
    }
}
