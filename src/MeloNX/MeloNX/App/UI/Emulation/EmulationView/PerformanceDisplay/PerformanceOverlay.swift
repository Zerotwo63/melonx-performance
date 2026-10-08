//
//  Untitled.swift
//  MeloNX
//
//  Created by Stossy11 on 21/12/2024.
//

import SwiftUI

struct PerformanceOverlayView: View  {
    @StateObject private var memorymonitor = MemoryUsageMonitor()

    @StateObject private var fpsmonitor = FPSMonitor()
    @StateObject private var benchmarkManager = BenchmarkManager()
    @ObservedObject private var framePacingMonitor = FramePacingMonitor.shared
    @ObservedObject private var autoPerformance = AutoPerformanceManager.shared
    @State private var batteryLevel: Int = Int(UIDevice.current.batteryLevel * 100)

    @AppStorage("showBatteryPercentage") var showBatteryPercentage: Bool = false

    @AppStorage("horizontalorvertical") var horizontalorvertical: Bool = false

    /// Objective start/stop measurement (BenchmarkManager) rather than
    /// just the live, unrecorded FPS text above — see
    /// App/Core/Performance/BenchmarkManager.swift.
    @ViewBuilder
    private var benchmarkControl: some View {
        Button {
            if benchmarkManager.isRunning {
                benchmarkManager.stop()
            } else {
                benchmarkManager.start()
            }
        } label: {
            Text(benchmarkManager.isRunning ? "Stop Benchmark" : "Benchmark")
                .foregroundStyle(.white)
        }

        if !benchmarkManager.isRunning, let result = benchmarkManager.lastResult {
            Text(String(format: "Avg %.0f / 1%% low %.0f / Min %.0f FPS", result.averageFPS, result.fps1PercentLow, result.minFPS))
                .foregroundStyle(.white)
                .font(.caption2)
            Text("\(result.activeScalingFilter.displayName) @ \(String(format: "%.2f", result.resolutionScale))x · jitter \(String(format: "%.1f", result.worstFrameJitter * 1000))ms")
                .foregroundStyle(.white)
                .font(.caption2)
            // "FIFO thread" (not "GPU") deliberately - see
            // RyujinxBridge.fifoThreadBusyPercent's doc comment: this is
            // host-side GPU-command-translation thread load, not a
            // physical GPU hardware utilization reading.
            Text(String(format: "Frametime P95 %.1f / P99 %.1fms · FIFO thread %.0f%%", result.frameTimeP95Ms, result.frameTimeP99Ms, result.fifoThreadBusyPercent))
                .foregroundStyle(.white)
                .font(.caption2)
        }
    }

    /// True frame-pacing (interval evenness), not just average FPS — see
    /// App/Core/Performance/FramePacingMonitor.swift.
    @ViewBuilder
    private var framePacingControl: some View {
        Button {
            if framePacingMonitor.isRunning {
                framePacingMonitor.stop()
            } else {
                framePacingMonitor.start()
            }
        } label: {
            Text(framePacingMonitor.isRunning ? "Stop Frame Pacing" : "Frame Pacing")
                .foregroundStyle(.white)
        }

        if !framePacingMonitor.isRunning, let result = framePacingMonitor.lastResult {
            Text(String(format: "Jitter %.1fms / Display %dHz", result.worstJitter * 1000, result.deviceMaximumFPS))
                .foregroundStyle(.white)
                .font(.caption2)
        }
    }

    @ViewBuilder
    var content: some View {
        if horizontalorvertical {
            HStack(spacing: 8) {
                if showBatteryPercentage {
                    Text("Battery: \(batteryLevel)%")
                        .foregroundStyle(.white)
                }
                Text("\(fpsmonitor.formatFPS())")
                    .foregroundStyle(.white)
                Text("RAM: " + memorymonitor.formatMemorySize(memorymonitor.memoryUsage))
                    .foregroundStyle(.white)
                if autoPerformance.isThrottling {
                    Text(autoPerformance.isUsingAutoFSR ? "Throttled (FSR)" : "Throttled")
                        .foregroundStyle(.orange)
                }
                benchmarkControl
                framePacingControl
            }
            .padding(10)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                if showBatteryPercentage {
                    Text("Battery: \(batteryLevel)%")
                        .foregroundStyle(.white)
                }
                Text("\(fpsmonitor.formatFPS())")
                    .foregroundStyle(.white)
                Text("RAM: " + memorymonitor.formatMemorySize(memorymonitor.memoryUsage))
                    .foregroundStyle(.white)
                if autoPerformance.isThrottling {
                    Text(autoPerformance.isUsingAutoFSR ? "Throttled (FSR)" : "Throttled")
                        .foregroundStyle(.orange)
                }
                benchmarkControl
                framePacingControl
            }
            .padding(10)
            .frame(minWidth: 150)
        }
    }
    
    var body: some View {
        Group {
            if #available(iOS 19.0, *), !NativeSettingsManager.shared.disableLiquidGlass.value {
                GlassEffectContainer {
                    content
                        .glassEffect(.clear.tint(.black.opacity(0.6)),in: RoundedRectangle(cornerRadius: 5))
                }
            } else {
                content
                    .background(Color.black.opacity(0.7))
            }
        }
        .onAppear() {
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = Int(UIDevice.current.batteryLevel * 100)
            
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                batteryLevel = Int(UIDevice.current.batteryLevel * 100)
            }
        }
    }
}

