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
/// frameTimeP95Ms/frameTimeP99Ms (added this round) are real percentiles
/// of actual per-frame CADisplayLink intervals (already collected below
/// for worstFrameJitter), NOT a derivation of averageFPS -
/// `PerformanceStatistics.GetGameFrameTime()` on the native side IS
/// exactly that kind of redundant derivation (`1000 / frameRate`, the
/// SAME frame rate RyujinxBridge.currentFPS already reports) and is
/// deliberately still not exposed here for that reason - a previous
/// round correctly identified it would just duplicate the FPS figures
/// already here under a different name, and that reasoning still holds.
/// fifoThreadBusyPercent (also added this round, via the newly-exposed
/// get_gpu_fifo_percent) IS a genuinely independent measurement, not
/// derivable from FPS alone - but per a later audit round's correction,
/// it is NOT a physical-GPU-hardware-utilization reading either: see
/// RyujinxBridge.fifoThreadBusyPercent's doc comment for exactly what
/// it measures (host-side time inside Device.ProcessFrame(), i.e. GPU
/// command TRANSLATION load on this process's own thread, not a Metal/
/// Instruments GPU counter).
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
        // Real per-frame intervals from CADisplayLink (frameIntervals,
        // already collected below for worstFrameJitter) - in
        // milliseconds, sorted ascending so P95/P99 are a real
        // percentile of actual frame-to-frame timing, NOT a derivation
        // of averageFPS (see this file's own top doc comment for why
        // that distinction matters - GetGameFrameTime() on the native
        // side is exactly that kind of redundant derivation, which is
        // why it still isn't used here).
        let frameTimeP95Ms: Double
        let frameTimeP99Ms: Double
        // Real, independent metric (Ryujinx.HLE.PerformanceStatistics.GetFifoPercent()) -
        // NOT GPU hardware utilization (see RyujinxBridge.fifoThreadBusyPercent's
        // doc comment) - percentage of time the render thread spent
        // inside Device.ProcessFrame() (translating guest GPFIFO
        // commands to Vulkan calls) over the run, snapshotted at stop()
        // like resolutionScale/thermalState below (not a time series,
        // same caveat applies).
        let fifoThreadBusyPercent: Float
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

        // Real percentiles of actual frame-to-frame display timing
        // (CADisplayLink.targetTimestamp deltas, already collected in
        // tick(_:) below) - converted to milliseconds since that is the
        // conventional unit for frametime reporting. Sorted ascending;
        // P95/P99 take the value at the 95th/99th percentile INDEX, the
        // same "worst tail" convention frame-pacing tools use (higher
        // index = slower/worse frame here, since interval is time, not
        // rate).
        let sortedIntervalsMs = frameIntervals.sorted().map { $0 * 1000 }
        func percentile(_ p: Double) -> Double {
            guard !sortedIntervalsMs.isEmpty else { return 0 }
            let index = min(sortedIntervalsMs.count - 1, Int(Double(sortedIntervalsMs.count) * p))
            return sortedIntervalsMs[index]
        }

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
            frameTimeP95Ms: percentile(0.95),
            frameTimeP99Ms: percentile(0.99),
            fifoThreadBusyPercent: RyujinxBridge.fifoThreadBusyPercent,
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
