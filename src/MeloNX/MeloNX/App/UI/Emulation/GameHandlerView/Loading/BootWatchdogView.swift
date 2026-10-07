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
        ScrollView {
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

            VStack(alignment: .leading, spacing: 6) {
                row("Managed thread alive", "\(diagnostics.managedThreadAlive)")
                row("Render thread alive", "\(diagnostics.renderThreadAlive)")
                row("Last managed stage", diagnostics.lastManagedStage ?? "none")
                row("Last renderer stage", diagnostics.lastRendererStage ?? "none")
                row("Last Vulkan result", diagnostics.lastVulkanResult ?? "none")
                row("MetalView alive", "\(diagnostics.metalViewAlive)")
                row("Surface created", "\(diagnostics.surfaceCreated)")
            }

            VStack(alignment: .leading, spacing: 6) {
                row("Swapchain image count", diagnostics.swapchainImageCount.map { "\($0)" } ?? "unknown")
                row("Acquire attempted", "\(diagnostics.acquireAttempted)")
                row("Acquire count", "\(diagnostics.acquireAttemptCount)")
                row("First acquire succeeded", "\(diagnostics.firstAcquireSucceeded)")
                row("Last acquire result", diagnostics.lastAcquireResult ?? "none")
                row("Command buffer started", "\(diagnostics.commandBufferStarted)")
                row("Command buffer recorded", "\(diagnostics.commandBufferRecorded)")
                row("Last submit result", diagnostics.lastSubmitResult ?? "none")
                row("Last present result", diagnostics.lastPresentResult ?? "none")
                row("Render loop entered", "\(diagnostics.renderLoopEntered)")
                row("Render loop iterations", "\(diagnostics.renderLoopIterations)")
                row("Last render loop stage", diagnostics.lastRenderLoopStage ?? "none")
                row("Seconds since render progress", diagnostics.secondsSinceLastRenderProgress().map { String(format: "%.1fs", $0) } ?? "n/a")
            }

            Text("GUEST").font(.caption).bold().foregroundColor(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                row("Guest main thread created", "\(diagnostics.guestMainThreadCreated)")
                row("Guest main thread started", "\(diagnostics.guestMainThreadStarted)")
                row("Guest main thread alive", "\(diagnostics.guestMainThreadAlive)")
                row("Guest thread count", "\(diagnostics.guestThreadCount)")
                row("Guest execution heartbeats", "\(diagnostics.guestExecutionHeartbeats)")
                row("Translated functions created", "\(diagnostics.translatedFunctionsCreated)")
                row("Translated functions executed", "\(diagnostics.translatedFunctionsExecuted)")
                row("Last guest stage", diagnostics.lastGuestStage ?? "none")
            }

            Text("GPU PRODUCER").font(.caption).bold().foregroundColor(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                row("GPU context created", "\(diagnostics.gpuContextCreated)")
                row("GPU channels created", "\(diagnostics.gpuChannelsCreated)")
                row("gpfifo submissions", "\(diagnostics.gpfifoSubmissions)")
                row("FIFO commands queued", "\(diagnostics.fifoCommandsQueued)")
                row("FIFO commands consumed", "\(diagnostics.fifoCommandsConsumed)")
                row("FIFO wait calls", "\(diagnostics.fifoWaitCalls)")
                row("FIFO wait true", "\(diagnostics.fifoWaitTrue)")
                row("FIFO wait false", "\(diagnostics.fifoWaitFalse)")
                row("Last GPU producer stage", diagnostics.lastGpuProducerStage ?? "none")
                row("Last Nv stage", diagnostics.lastNvStage ?? "none")
                row("Last translator stage", diagnostics.lastTranslatorStage ?? "none")
            }

            Text("TRANSLATOR (real backend)").font(.caption).bold().foregroundColor(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                row("Context.Execute entered", "\(diagnostics.contextExecuteEntered)")
                row("Context.Execute returned", "\(diagnostics.contextExecuteReturned)")
                row("Translator.Execute entered", "\(diagnostics.translatorExecuteEntered)")
                row("Translator lookup attempts", "\(diagnostics.translatorLookupAttempts)")
                row("Translation attempts", "\(diagnostics.translationAttempts)")
                row("NOP fallback count", "\(diagnostics.nopFallbackCount)")
                row("JIT code allocations", "\(diagnostics.jitCodeAllocations)")
                row("JIT bytes generated", "\(diagnostics.jitBytesGenerated)")
                row("First guest PC", diagnostics.firstGuestPc ?? "none")
                row("Last guest PC", diagnostics.lastGuestPc ?? "none")
                row("JIT RW address", diagnostics.jitRwAddress ?? "none")
                row("JIT RX address", diagnostics.jitRxAddress ?? "none")
                row("Host function call attempted", "\(diagnostics.hostFunctionCallAttempted)")
                row("Host function call returned", "\(diagnostics.hostFunctionCallReturned)")
            }

            Text("THREAD SNAPSHOT").font(.caption).bold().foregroundColor(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                row("GPU thread alive", "\(diagnostics.gpuThreadAlive)")
                row("FIFO producer alive", "\(diagnostics.fifoProducerAlive)")
            }

            Text("Failure stage: \(diagnostics.failureStage ?? "none")\nLast error: \(diagnostics.failureReason ?? "none")")
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
        }
        .frame(maxHeight: 600)
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
