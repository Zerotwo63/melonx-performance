//
//  FramePacingMonitor.swift
//  MeloNX
//

import Foundation
import UIKit

/// Objective measurement of display frame-pacing smoothness — distinct
/// from BenchmarkManager's average/min/max FPS, which says nothing about
/// whether frames arrive evenly spaced or in bursts with gaps. A game
/// can average 60 FPS while still visibly stuttering if the intervals
/// between frames are uneven; that's what this measures instead.
///
/// Uses CADisplayLink — the real system signal for display refresh
/// timing, not a reinvented timer — and reads its own targetTimestamp
/// deltas, which reflect the device's actual display cadence (including
/// ProMotion's real variable-refresh behavior). This file does not touch
/// MetalView.swift's rendering/presentation setup at all; it's a
/// parallel, independent observer.
///
/// Documented finding from reading MetalView.swift (not fixed here — see
/// PERFORMANCE_FORK.md): the device's real maximum refresh rate is
/// UIScreen.main.maximumFramesPerSecond, but MetalView.swift
/// unconditionally sets the Metal layer's nominalFramesPerSecond to a
/// hardcoded 60 and disables displaySyncEnabled entirely, regardless of
/// the user's own VSync setting (Ryujinx.Arguments.disablevsync, which
/// only controls the *emulated console's* internal pacing — a
/// completely separate thing from the Metal layer's own compositor
/// sync). Whether that's an intentional decoupling (avoiding the
/// compositor imposing a second, conflicting pacing authority on top of
/// the emulator's own internal frame timing, which this Swift-side code
/// has no visibility into) or an oversight isn't something readable from
/// the source alone — it needs real frame-pacing data from a physical
/// device, which is exactly what this monitor collects, rather than
/// guessing and changing rendering-critical code with no way to verify
/// the result here.
@MainActor
final class FramePacingMonitor: NSObject, ObservableObject {
    struct Result {
        let duration: TimeInterval
        let sampleCount: Int
        let averageInterval: TimeInterval
        let worstJitter: TimeInterval
        let deviceMaximumFPS: Int
    }

    static let shared = FramePacingMonitor()

    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: Result?

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [TimeInterval] = []
    private var startedAt: Date?

    private override init() {
        super.init()
    }

    func reset() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
        startedAt = nil
        lastTimestamp = nil
        intervals = []
        lastResult = nil
    }

    func start() {
        guard displayLink == nil else { return }

        isRunning = true
        startedAt = Date()
        lastTimestamp = nil
        intervals = []

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @discardableResult
    func stop() -> Result? {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false

        guard let startedAt, !intervals.isEmpty else { return nil }

        let average = intervals.reduce(0, +) / Double(intervals.count)
        let worstJitter = intervals.map { abs($0 - average) }.max() ?? 0

        let result = Result(
            duration: Date().timeIntervalSince(startedAt),
            sampleCount: intervals.count,
            averageInterval: average,
            worstJitter: worstJitter,
            deviceMaximumFPS: UIScreen.main.maximumFramesPerSecond
        )

        lastResult = result
        self.startedAt = nil
        return result
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let lastTimestamp {
            intervals.append(link.targetTimestamp - lastTimestamp)
        }
        lastTimestamp = link.targetTimestamp
    }
}
