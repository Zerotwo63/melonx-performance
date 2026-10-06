//
//  BootWatchdogView.swift
//  MeloNX
//

import SwiftUI
import UIKit

/// Shown over Loading once the boot watchdog fires (15s past
/// "ryujinx.start begin" with no "ran-first-frame") - "Loading" must
/// never again be the only thing the user sees forever with zero
/// information. Must accept touches even while Loading's own content is
/// still visible underneath.
struct BootWatchdogView: View {
    @ObservedObject private var diagnostics = BootDiagnostics.shared
    let onExit: () -> Void

    @State private var showCopiedConfirmation = false
    @State private var showSavedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GAME BOOT DIAGNOSTICS")
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                row("Environment", diagnostics.environment ?? "unknown")
                row("JIT verified", diagnostics.jitVerified.map { "\($0)" } ?? "unknown")
                row("Dual mapped JIT", diagnostics.dualMappedJIT.map { "\($0)" } ?? "unknown")
                row("Last stage", diagnostics.lastStage)
                row("Elapsed", elapsedText)
            }

            VStack(alignment: .leading, spacing: 6) {
                row("Ryujinx started", "\(diagnostics.ryujinxStarted)")
                row("Swapchain created", "\(diagnostics.swapchainCreated)")
                row("First submit", "\(diagnostics.firstSubmit)")
                row("First present", "\(diagnostics.firstPresent)")
                row("First frame", "\(diagnostics.firstFrame)")
            }

            Text("Last error: \(diagnostics.failureReason ?? "none")")
                .font(.footnote)
                .foregroundColor(diagnostics.failureReason == nil ? .white.opacity(0.6) : .red)

            HStack(spacing: 12) {
                Button("Copy Diagnostics") {
                    UIPasteboard.general.string = diagnostics.buildReport()
                    withAnimation { showCopiedConfirmation = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { showCopiedConfirmation = false }
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Save Diagnostics") {
                    _ = diagnostics.saveReportToDisk()
                    withAnimation { showSavedConfirmation = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { showSavedConfirmation = false }
                    }
                }
                .buttonStyle(.bordered)

                Button("Exit Game", role: .destructive) {
                    onExit()
                }
                .buttonStyle(.bordered)
            }

            if showCopiedConfirmation {
                Text("Copied").font(.caption).foregroundColor(.green)
            }
            if showSavedConfirmation {
                Text("Saved to Documents/Diagnostics/boot-report.txt").font(.caption).foregroundColor(.green)
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .background(Color.black.opacity(0.92))
        .cornerRadius(16)
        .padding()
        .allowsHitTesting(true)
    }

    private var elapsedText: String {
        guard let last = diagnostics.stages.last else { return "-" }
        return String(format: "%.1fs", last.elapsed)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(value)
                .foregroundColor(.white)
                .font(.system(.body, design: .monospaced))
        }
    }
}
