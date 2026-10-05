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
            Text(String(format: "Avg %.0f / Min %.0f / Max %.0f FPS", result.averageFPS, result.minFPS, result.maxFPS))
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
                    Text("Throttled")
                        .foregroundStyle(.orange)
                }
                benchmarkControl
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
                    Text("Throttled")
                        .foregroundStyle(.orange)
                }
                benchmarkControl
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

