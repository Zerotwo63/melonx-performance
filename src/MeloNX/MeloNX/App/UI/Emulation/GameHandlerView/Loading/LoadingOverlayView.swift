//
//  LoadingOverlayView.swift
//  MeloNX
//
//  Created by Stossy11 on 07/11/2025.
//

import SwiftUI

struct LoadingOverlayView: View {
    let game: Game?
    let showLogs: Bool
    let startEmulationCallback: () -> Void

    @EnvironmentObject var gameHandler: LaunchGameHandler
    @EnvironmentObject var ryujinx: Ryujinx

    @State private var isLoading = true
    @State private var isAnimating = false
    @State private var isShaderOrPTC = false
    @State private var loadingType = ""
    @State private var currentProgress = 0
    @State private var totalProgress = 1
    @State private var showWatchdog = false
    @State private var watchdogTask: Task<Void, Never>?

    private let clumpWidth: CGFloat = 100

    /// 15s past "ryujinx.start begin" with no "ran-first-frame" - "Loading"
    /// must never again be the only thing the user sees, forever, with no
    /// information about where it actually stopped.
    private let watchdogTimeout: UInt64 = 15_000_000_000

    var body: some View {
        if isLoading {
            ZStack {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()

                GeometryReader { screenGeometry in
                    ZStack {
                        loadingContent(screenGeometry: screenGeometry)

                        if showLogs {
                            VStack {
                                LogView(isfps: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer()
                            }
                        }
                    }
                }

                if showWatchdog {
                    BootWatchdogView(onExit: exitGame)
                        .allowsHitTesting(true)
                }
            }
            .transition(.opacity)
            .onAppear {
                setupLoading()
            }
            .onDisappear {
                watchdogTask?.cancel()
            }
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            try? await Task.sleep(nanoseconds: watchdogTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if isLoading {
                    showWatchdog = true
                    // The watchdog firing with no prior fail() call IS
                    // itself a real, distinct failure - "nothing reached
                    // swapchain/submit/present/frame within the timeout",
                    // not the absence of information failureStage=none
                    // used to silently imply.
                    let diag = BootDiagnostics.shared
                    if diag.failureStage == nil {
                        let progress = diag.secondsSinceLastRenderProgress().map { String(format: "%.1fs", $0) } ?? "n/a"
                        diag.fail(
                            stage: "boot watchdog",
                            reason: "timeout waiting for swapchain/first frame; lastManagedStage=\(diag.lastManagedStage ?? "none"), lastRendererStage=\(diag.lastRendererStage ?? "none"), lastRenderLoopStage=\(diag.lastRenderLoopStage ?? "none"), secondsSinceLastRenderProgress=\(progress), lastAcquireResult=\(diag.lastAcquireResult ?? "none"), lastSubmitResult=\(diag.lastSubmitResult ?? "none"), lastPresentResult=\(diag.lastPresentResult ?? "none")"
                        )
                    }
                }
            }
        }
    }

    /// Minimal, same effect as EmulationView.stop() - duplicated rather
    /// than reached into from here, since this view has no direct access
    /// to that one's local state and the recovery action itself is only
    /// a few lines.
    private func exitGame() {
        gameHandler.showApp = true
        gameHandler.currentGame = nil
        RyujinxBridge.stopEmulation()
        try? ryujinx.stop()
    }
    
    private func loadingContent(screenGeometry: GeometryProxy) -> some View {
        HStack(spacing: screenGeometry.size.width * 0.04) {
            if let icon = game?.icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: min(screenGeometry.size.width * 0.25, 250),
                        height: min(screenGeometry.size.width * 0.25, 250)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
            }
            
            VStack(alignment: .leading, spacing: screenGeometry.size.height * 0.015) {
                Text("Loading \(game?.titleName ?? "Game")")
                    .font(.system(size: min(screenGeometry.size.width * 0.04, 32), weight: .semibold))
                    .foregroundColor(.white)
                
                LoadingProgressBar(
                    screenGeometry: screenGeometry,
                    isAnimating: $isAnimating,
                    isShaderOrPTC: isShaderOrPTC,
                    currentProgress: currentProgress,
                    totalProgress: totalProgress,
                    clumpWidth: clumpWidth
                )
                
                if isShaderOrPTC {
                    Text("\(loadingType): \(currentProgress)/\(totalProgress)")
                        .font(.system(size: min(screenGeometry.size.width * 0.03, 16)))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, screenGeometry.size.width * 0.06)
        .padding(.vertical, screenGeometry.size.height * 0.05)
        .position(
            x: screenGeometry.size.width / 2,
            y: screenGeometry.size.height * 0.5
        )
    }
    
    private func setupLoading() {
        isAnimating = true
        Ryujinx.shared.showLoading = true
        
        RegisterCallbackWithData("ProgressWithPTCorShaderCache") { data in
            guard let rawData = data,
                  let jsonArray = try? JSONSerialization.jsonObject(with: rawData, options: []) as? [Any],
                  jsonArray.count == 3,
                  let type = jsonArray[0] as? String,
                  let current = jsonArray[1] as? Int,
                  let total = jsonArray[2] as? Int else {
                Task { @MainActor in
                    self.isShaderOrPTC = false
                }
                return
            }
            
            if !NativeSettingsManager.shared.showlogsgame.value {
                // LogCapture.shared.stopCapturing()
            }
            
            Task { @MainActor in
                if current < total - 1 {
                    self.isShaderOrPTC = true
                    self.loadingType = type
                    self.currentProgress = current
                    self.totalProgress = total
                } else {
                    self.isShaderOrPTC = false
                }
            }
        }
        
        startEmulationCallback()
        startWatchdog()

        RegisterCallback("ran-first-frame") { _ in
            print("cool, first frame! :3")
            // Exact string "ran-first-frame" matters - BootDiagnostics'
            // applyKnownStage() switches on it exactly to cross-check this
            // engine-level signal against the real queuePresent result.
            BootDiagnostics.shared.log("ran-first-frame")
            Task { @MainActor in
                watchdogTask?.cancel()
                withAnimation(.easeOut(duration: 0.3)) {
                    if let game {
                        Task {
                           //  await GamePlaytimeManager.shared.startSavingPlaytime(game)
                        }
                    }
                    isLoading = false
                    isAnimating = false
                    showWatchdog = false
                    Ryujinx.shared.showLoading = false
                }
            }
        }
    }
}

