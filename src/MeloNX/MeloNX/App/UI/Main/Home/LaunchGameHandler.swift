//
//  LaunchGameHandler.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import Combine
import Foundation
import SwiftUI

class LaunchGameHandler: ObservableObject {
    @Published var currentGame: Game? = nil
    @Published var profileSelected = false
    @Published var showApp: Bool = true
    @Published var isPortrait: Bool = true
    @AppStorage("gametorun") var gametorun: String = ""
    @AppStorage("gametorun-date") var gametorunDate: String = ""
    
    static var succeededJIT: Bool = true
    
    private static let jitEntitlement = "com.apple.developer.kernel.increased-memory-limit"
    
    private let ryujinx = Ryujinx.shared
    private let nativeSettings = NativeSettingsManager.shared
    private let settingsManager = SettingsManager.shared
    private let persettings = PerGameSettingsManager.shared
    private let controllerManager = ControllerManager.shared
    
    private var config: Ryujinx.Arguments {
        settingsManager.config
    }
    
    private var hasJITEntitlement: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac ? true : checkAppEntitlement(Self.jitEntitlement)
    }
    
    var isGameReady: Bool {
        currentGame != nil
            && (nativeSettings.ignoreJIT.value ? true : ryujinx.jitenabled)
            && (nativeSettings.showProfileonGame.value ? profileSelected : true)
    }
    
    var shouldLaunchGame: Bool {
        // The increased-memory entitlement is useful, but it must not hide the
        // actual JIT flow or make a free-signed build look completely dead.
        // Let the emulator attempt to launch once JIT/profile requirements are
        // satisfied; Settings still reports whether the entitlement is present.
        isGameReady
    }
    
    var shouldShowEntitlement: Bool {
        // Informational only in this fork. Blocking here prevented the JIT
        // sheet from ever appearing on AltStore builds that cannot carry the
        // increased-memory entitlement.
        false
    }
    
    var shouldShowPopover: Bool {
        currentGame != nil
            && ryujinx.jitenabled
            && !profileSelected
            && nativeSettings.showProfileonGame.value
    }
    
    var shouldCheckJIT: Bool {
        currentGame != nil
            && !ryujinx.jitenabled
            && !(nativeSettings.ignoreJIT.value as Bool)
    }
    
    
    
    /// MeloNX's own internal JIT path (JITStreamerEB, via the existing
    /// LocalDevVPN tunnel) is tried first, unconditionally — it needs no
    /// app installed on-device beyond that VPN, so it's never a
    /// requirement to have StikDebug/StikJIT/TrollStore around.
    /// TrollStore/StikDebug/Built-in StikJIT only run as fallbacks, and
    /// only for whichever one the user has actually toggled on — this
    /// doesn't change their existing behavior, it only runs after the
    /// internal attempt has had a real chance to succeed or fail.
    ///
    /// Inside LiveContainer this function does NOT attempt any of that -
    /// LiveContainer only launches MeloNX after its own StikDebug JIT
    /// hand-off already completed, so MeloNX trying JITStreamerEB/
    /// TrollStore/StikDebug/Built-in StikJIT on top of that would be
    /// redundant at best and could interfere with an already-correct
    /// state at worst. It only verifies and reports.
    func enableJIT() {
        ryujinx.checkForJIT()
        JITCoordinator.shared.beginAcquisitionCycle()

        JITCoordinator.shared.logDiag("[JIT] checking already-acquired state")
        let alreadyAvailable = isJITEnabled()
        JITCoordinator.shared.logDiag("[JIT] jitAlreadyAvailable = \(alreadyAvailable)")

        let pretest = JITDiagnostics.probeExecutableMemory()
        JITCoordinator.shared.logDiag("[JIT] executable-memory pretest = \(pretest.overallSuccess)")

        print("[JIT] activation requested")
        print("[JIT] request started")
        print("[JIT] current state = \(JITCoordinator.shared.state)")
        print("Has TXM? \(ProcessInfo.processInfo.hasTXM)")

        guard !ryujinx.jitenabled else { return }

        gametorunDate = "\(Date().timeIntervalSince1970)"
        gametorun = currentGame?.titleId ?? ""

        if RuntimeEnvironment.isLiveContainer {
            JITCoordinator.shared.logDiag("[JIT] environment = LiveContainer")
            JITCoordinator.shared.logDiag("[JIT] using external JIT")
            JITCoordinator.shared.logDiag("[JIT] internal acquisition skipped")
            JITCoordinator.shared.logDiag("[LCJIT] detected LiveContainer")
            JITCoordinator.shared.logDiag("[LCJIT] external JIT expected")

            JITCoordinator.shared.logDiag("[JIT] verification begin")
            let verified = isJITEnabled()
            JITCoordinator.shared.logDiag("[JIT] verification result = \(verified)")
            JITCoordinator.shared.logDiag("[LCJIT] process verification = \(verified)")
            // hasTXM is the same real signal enableJITStik() already uses to
            // decide whether StikDebug's script-based (universal.js/JIT26)
            // protocol is required on this device, rather than plain
            // debugger-attach being enough - not a new, invented condition.
            JITCoordinator.shared.logDiag("[LCJIT] universal/JIT26 compatibility = \(ProcessInfo.processInfo.hasTXM)")

            if !verified {
                JITCoordinator.shared.failImmediately(reason: "LiveContainer launched MeloNX but external JIT was not verified.")
            }
            return
        }

        JITCoordinator.shared.logDiag("[JIT] enabled methods = \(JITDiagnostics.enabledMethodNames().joined(separator: ", "))")

        Task { @MainActor in
            let jsebAttempt = JITCoordinator.shared.beginAttempt("JITStreamerEB", detected: true, enabled: true)
            JITCoordinator.shared.logDiag("[JIT] starting JITStreamerEB")

            let acquired = await JITStreamerEB.attach()
            JITCoordinator.shared.logDiag("[JIT] JITStreamerEB returned \(acquired)")

            JITCoordinator.shared.logDiag("[JIT] verifying executable memory")
            let jsebProbe = JITDiagnostics.probeExecutableMemory()
            JITCoordinator.shared.logDiag("[JIT] verification result = \(jsebProbe.overallSuccess)")
            JITCoordinator.shared.logDiag("[JIT] errno = \(jsebProbe.errnoValue) (\(jsebProbe.errorDescription.isEmpty ? "none" : jsebProbe.errorDescription))")

            JITCoordinator.shared.updateAttempt(jsebAttempt) { attempt in
                attempt.attempted = true
                attempt.result = acquired ? "success" : "failed"
                attempt.error = acquired ? nil : "internal JIT server unreachable or attach request failed"
                attempt.errnoValue = jsebProbe.errnoValue
                attempt.connectionStatus = acquired ? "reachable" : "unreachable"
            }
            JITCoordinator.shared.finishAttempt(jsebAttempt)

            guard !acquired else {
                JITCoordinator.shared.logDiag("[JIT] final result = SUCCESS")
                return
            }

            print("[JIT] fallback selected")

            if self.nativeSettings.useTrollStore.value {
                let attempt = JITCoordinator.shared.beginAttempt("TrollStore", detected: true, enabled: true)
                JITCoordinator.shared.logDiag("[JIT] starting TrollStore")
                askForJIT()
                // TrollStore hands off to the OS/another process - MeloNX has
                // no synchronous result here. JITCoordinator's own poll is
                // the only thing allowed to decide acquired/failed.
                JITCoordinator.shared.updateAttempt(attempt) { attempt in
                    attempt.attempted = true
                    attempt.result = "started (external, result observed via JITCoordinator's poll)"
                    attempt.connectionStatus = "unknown (external app)"
                }
                JITCoordinator.shared.finishAttempt(attempt)
            } else if self.nativeSettings.stikJIT.value {
                let tool = detectStikTool()
                let detected = tool != .notFound
                JITCoordinator.shared.logDiag("[JIT] pairing available = unknown (external app manages its own pairing)")
                JITCoordinator.shared.logDiag("[JIT] connection = \(detected ? "app reachable" : "not reachable - no URL scheme handler found")")

                let attempt = JITCoordinator.shared.beginAttempt("StikJIT", detected: detected, enabled: true)
                JITCoordinator.shared.logDiag("[JIT] attempt starting StikJIT")
                enableJITStik()
                JITCoordinator.shared.updateAttempt(attempt) { attempt in
                    attempt.attempted = true
                    attempt.result = detected ? "started (external, result observed via JITCoordinator's poll)" : "failed"
                    attempt.error = detected ? nil : "no StikDebug/StikJIT URL scheme handler found on this device"
                    attempt.pairingStatus = "unknown (external app manages its own pairing)"
                    attempt.connectionStatus = detected ? "app reachable" : "not reachable"
                }
                JITCoordinator.shared.finishAttempt(attempt)
            } else if BuiltInStikJITAvailability.isAvailable {
                // If the embedded helper is usable, prefer it automatically.
                // Requiring the user to discover and toggle it first made the
                // "no third app" path effectively unreachable.
                self.nativeSettings.builtInStikJIT.value = true
                let pairingAvailable = BuiltInStikJITAvailability.hasImportedPairingFile
                JITCoordinator.shared.logDiag("[JIT] pairing available = \(pairingAvailable)")

                let attempt = JITCoordinator.shared.beginAttempt("builtInStikJIT", detected: true, enabled: true)
                JITCoordinator.shared.logDiag("[JIT] starting builtInStikJIT")

                let builtInAcquired = await MeloNXBuiltInJIT.enableCurrentProcess()
                JITCoordinator.shared.logDiag("[JIT] builtInStikJIT returned \(builtInAcquired)")

                JITCoordinator.shared.logDiag("[JIT] verifying executable memory")
                let verified = isJITEnabled()
                let probe = JITDiagnostics.probeExecutableMemory()
                JITCoordinator.shared.logDiag("[JIT] verification result = \(verified)")
                JITCoordinator.shared.logDiag("[JIT] errno = \(probe.errnoValue) (\(probe.errorDescription.isEmpty ? "none" : probe.errorDescription))")

                JITCoordinator.shared.updateAttempt(attempt) { attempt in
                    attempt.attempted = true
                    attempt.result = verified ? "success" : "failed"
                    attempt.error = verified ? nil : (builtInAcquired
                        ? "enableCurrentProcess reported success but isJITEnabled() is still false"
                        : "enableCurrentProcess did not grant JIT")
                    attempt.pairingStatus = "\(pairingAvailable)"
                    attempt.errnoValue = probe.errnoValue
                }
                JITCoordinator.shared.finishAttempt(attempt)

                if !verified {
                    print("[JIT] failed reason = built-in activation did not grant JIT on this process")
                }
            } else {
                let reason = BuiltInStikJITAvailability.unavailableReason().map(JITDiagnostics.reasonText(for:))
                    ?? "the built-in JIT helper could not be started"

                let attempt = JITCoordinator.shared.beginAttempt("builtInStikJIT", detected: false, enabled: false)
                JITCoordinator.shared.logDiag("[JIT] reasonUnavailable = \(reason)")
                JITCoordinator.shared.updateAttempt(attempt) { attempt in
                    attempt.attempted = false
                    attempt.result = "not attempted"
                    attempt.error = reason
                    attempt.pairingStatus = "\(BuiltInStikJITAvailability.hasImportedPairingFile)"
                }
                JITCoordinator.shared.finishAttempt(attempt)

                print("[JIT] no fallback available")
                // This is a definitive, terminal failure - nothing left to
                // try will change the outcome, so stop JITCoordinator's poll
                // now instead of waiting out the rest of its cap for a
                // result that can't change.
                JITCoordinator.shared.failImmediately(reason: "no JIT method is available: the internal JITStreamerEB path failed and no fallback is enabled/available (\(reason))")

                if self.currentGame != nil {
                    presentAlert(
                        title: "JIT Not Acquired",
                        message: "Your Switch keys and firmware are already installed. They do not enable JIT. The internal JitStreamer server was not reachable, and the built-in fallback is unavailable because \(reason)."
                    )
                }
            }
        }
    }
    
    /// Root cause fixed here (reported after Hollow Knight stuck on
    /// "Loading" past swapchain creation): this used to call enableJIT()
    /// and fall straight through to MetalView.createView()/ryujinx.start()
    /// without ever waiting for enableJIT()'s async result - Ryujinx could
    /// start while JIT readiness was still unresolved. It also always
    /// tried MeloNX's own internal JIT methods even inside LiveContainer,
    /// where LiveContainer+StikDebug already own that job before MeloNX
    /// ever launches.
    ///
    /// Now: branch once on environment, verify (never silently skip
    /// verification), and only a single startGameAfterJITConfirmed() may
    /// touch MetalView/Ryujinx - never with JIT still pending or false.
    func startGame() {
        BootDiagnostics.shared.beginBoot()
        BootDiagnostics.shared.log("startGame called")
        BootDiagnostics.shared.log("PID", result: "\(getpid())")
        RuntimeEnvironment.logDetection()

        if RuntimeEnvironment.isLiveContainer {
            verifyExternalJITAndContinue()
        } else {
            acquireNativeJITAndContinue()
        }
    }

    /// LiveContainer already completed its own JIT hand-off (via StikDebug)
    /// before launching MeloNX at all - this only verifies that process
    /// state with the same isJITEnabled() the rest of the app trusts, it
    /// never attempts acquisition itself.
    private func verifyExternalJITAndContinue() {
        BootDiagnostics.shared.log("JIT verification begin")
        let startedAt = Date()
        let verified = isJITEnabled()
        let duration = Date().timeIntervalSince(startedAt)
        BootDiagnostics.shared.log("JIT verification result", result: "\(verified)")
        BootDiagnostics.shared.log("JIT verification duration", result: String(format: "%.3fs", duration))

        guard verified else {
            let reason = "LiveContainer launched MeloNX but external JIT was not verified."
            BootDiagnostics.shared.fail(stage: "JIT verification", reason: reason)
            if currentGame != nil {
                presentAlert(title: "JIT Not Verified", message: reason)
            }
            return
        }

        startGameAfterJITConfirmed()
    }

    /// Native (non-LiveContainer): if JIT is already confirmed (the common
    /// case - JITPopover already drove it to true before this fullScreenCover
    /// could even appear), proceeds immediately. Otherwise genuinely waits
    /// for JITCoordinator's real result instead of racing ahead of it.
    private func acquireNativeJITAndContinue() {
        BootDiagnostics.shared.log("JIT verification begin")

        if ryujinx.jitenabled {
            BootDiagnostics.shared.log("JIT verification result", result: "true")
            startGameAfterJITConfirmed()
            return
        }

        let startedAt = Date()
        JITCoordinator.shared.waitForJIT(trigger: { [weak self] in self?.enableJIT() }, maxAttempts: 60, interval: 0.5) { [weak self] success in
            let duration = Date().timeIntervalSince(startedAt)
            BootDiagnostics.shared.log("JIT verification result", result: "\(success)")
            BootDiagnostics.shared.log("JIT verification duration", result: String(format: "%.3fs", duration))

            guard success else {
                BootDiagnostics.shared.fail(
                    stage: "JIT verification",
                    reason: JITCoordinator.shared.lastFailureReason ?? "JIT could not be acquired before launch."
                )
                return
            }

            self?.startGameAfterJITConfirmed()
        }
    }

    /// The only function allowed to touch MetalView/Ryujinx - never
    /// reachable with JIT still pending or false.
    private func startGameAfterJITConfirmed() {
        MusicSelectorView.stopMusic()
        nativeSettings.isVirtualController.value = controllerManager.hasVirtualController()

        BootDiagnostics.shared.log("MetalView.createView begin")
        MetalView.createView()
        BootDiagnostics.shared.log("MetalView.createView end")

        guard let currentGame else { return }

        BootDiagnostics.shared.log("loading per-game config")
        persettings.loadSettings()

        var config = persettings.config[currentGame.titleId] ?? self.config

        controllerManager.registerControllerTypeForMatchingControllers()
        config.gamepath = currentGame.fileURL.path
        config.inputids = Array(Set(controllerManager.selectedControllers))

        if config.inputids.isEmpty {
            config.inputids.append("0")
        }
        BootDiagnostics.shared.log("per-game config loaded", result: "\(config.inputids)")

        BootDiagnostics.shared.log("configureEnvironmentVariables begin")
        guard configureEnvironmentVariables() else {
            presentAlert(
                title: "Boot Failed",
                message: "initialize_dualmapped failed before the game could start. See Game Boot Diagnostics for details."
            )
            return
        }
        BootDiagnostics.shared.log("command line args built")

        BootDiagnostics.shared.log("ryujinx.start begin")
        do {
            try ryujinx.start(with: config)
            BootDiagnostics.shared.log("ryujinx.start returned")
        } catch {
            BootDiagnostics.shared.fail(stage: "ryujinx.start", reason: error.localizedDescription)
            print("Failed to start game '\(currentGame.titleId)': \(error)")
        }
    }

    /// Returns false only when initialize_dualmapped() itself reports
    /// failure - per instruction, that must not be silently ignored.
    /// Known limitation, documented rather than hidden: initialize_dualmapped
    /// returns true even when DUAL_MAPPED_JIT isn't "1" at all, or when the
    /// dual-mapped cache construction merely didn't throw - a true here is
    /// not proof the CPU translator's real JIT path works at runtime. This
    /// function reports what the existing bridge call actually says, it
    /// does not invent a stronger check.
    @discardableResult
    private func configureEnvironmentVariables() -> Bool {
        let useDualMappedJIT: Bool
        if #available(iOS 19, *) {
            useDualMappedJIT = nativeSettings.setting(forKey: "DUAL_MAPPED_JIT", default: true).value
        } else {
            useDualMappedJIT = nativeSettings.setting(forKey: "DUAL_MAPPED_JIT", default: false).value
        }
        BootDiagnostics.shared.log("DUAL_MAPPED_JIT", result: "\(useDualMappedJIT)")

        if useDualMappedJIT {
            setenv("DUAL_MAPPED_JIT", "1", 1)

            BootDiagnostics.shared.log("initialize_dualmapped begin")
            let startedAt = Date()
            let result = RyujinxBridge.initialize_dualmapped()
            let duration = Date().timeIntervalSince(startedAt)

            Self.succeededJIT = result
            BootDiagnostics.shared.log("initialize_dualmapped result", result: "\(result)")
            BootDiagnostics.shared.log("initialize_dualmapped duration", result: String(format: "%.3fs", duration))

            if !result {
                BootDiagnostics.shared.fail(stage: "initialize_dualmapped", reason: "RyujinxBridge.initialize_dualmapped() returned false.")
                return false
            }
        } else {
            setenv("DUAL_MAPPED_JIT", "0", 1)
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", 1)
            return true
        }

        let supportsArgumentBuffersTier2 = device.argumentBuffersSupport.rawValue >= MTLArgumentBuffersTier.tier2.rawValue
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", supportsArgumentBuffersTier2 ? "1" : "0", 1)
        return true
    }
}
