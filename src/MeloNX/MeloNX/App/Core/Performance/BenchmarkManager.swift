//
//  BenchmarkManager.swift
//  MeloNX
//

import Foundation

/// Objective, structured performance measurement — the tool that makes a
/// later claim like "MetalFX made this faster" checkable instead of
/// anecdotal, per this fork's own stated priority on objective
/// measurement over impressions.
///
/// Reuses the exact signal sources FPSMonitor/MemoryUsageMonitor already
/// poll (RyujinxBridge.currentFPS, task_info's phys_footprint) rather
/// than inventing a new timing mechanism. RyujinxBridge exposes no
/// per-frame timestamps or GPU timings — only a periodically-updated FPS
/// scalar — so this reports statistics over sampled FPS readings, not
/// true frame-time percentiles. Don't oversell what's actually measured.
@MainActor
final class BenchmarkManager: ObservableObject {
    struct Result {
        let duration: TimeInterval
        let sampleCount: Int
        let averageFPS: Double
        let minFPS: Double
        let maxFPS: Double
        let averageMemory: UInt64
        let peakMemory: UInt64
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: Result?

    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var fpsSamples: [Double] = []
    private var memorySamples: [UInt64] = []

    func start() {
        guard !isRunning else { return }

        isRunning = true
        startedAt = Date()
        fpsSamples = []
        memorySamples = []

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
        isRunning = false
        self.startedAt = nil

        guard !fpsSamples.isEmpty else { return nil }

        let memoryCount = max(memorySamples.count, 1)
        let result = Result(
            duration: Date().timeIntervalSince(startedAt),
            sampleCount: fpsSamples.count,
            averageFPS: fpsSamples.reduce(0, +) / Double(fpsSamples.count),
            minFPS: fpsSamples.min() ?? 0,
            maxFPS: fpsSamples.max() ?? 0,
            averageMemory: memorySamples.reduce(0, +) / UInt64(memoryCount),
            peakMemory: memorySamples.max() ?? 0
        )

        lastResult = result
        return result
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
