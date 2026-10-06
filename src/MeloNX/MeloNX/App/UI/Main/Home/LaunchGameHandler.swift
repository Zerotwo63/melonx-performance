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
    func enableJIT() {
        ryujinx.checkForJIT()
        JITCoordinator.shared.beginAcquisitionCycle()

        JITCoordinator.shared.logDiag("[JIT] checking already-acquired state")
        let alreadyAvailable = isJITEnabled()
        JITCoordinator.shared.logDiag("[JIT] jitAlreadyAvailable = \(alreadyAvailable)")

        let pretest = JITDiagnostics.probeExecutableMemory()
        JITCoordinator.shared.logDiag("[JIT] executable-memory pretest = \(pretest.overallSuccess)")
        JITCoordinator.shared.logDiag("[JIT] enabled methods = \(JITDiagnostics.enabledMethodNames().joined(separator: ", "))")

        print("[JIT] activation requested")
        print("[JIT] request started")
        print("[JIT] current state = \(JITCoordinator.shared.state)")
        print("Has TXM? \(ProcessInfo.processInfo.hasTXM)")

        guard !ryujinx.jitenabled else { return }

        gametorunDate = "\(Date().timeIntervalSince1970)"
        gametorun = currentGame?.titleId ?? ""

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
                JITCoordinator.shared.recordFailure("no JIT method is available: the internal JITStreamerEB path failed and no fallback is enabled/available (\(reason))")

                if self.currentGame != nil {
                    presentAlert(
                        title: "JIT Not Acquired",
                        message: "Your Switch keys and firmware are already installed. They do not enable JIT. The internal JitStreamer server was not reachable, and the built-in fallback is unavailable because \(reason)."
                    )
                }
            }
        }
    }
    
    func startGame() {
        enableJIT()
        MusicSelectorView.stopMusic()
        nativeSettings.isVirtualController.value = controllerManager.hasVirtualController()
        MetalView.createView()
        
        guard let currentGame else { return }
        
        persettings.loadSettings()
        
        var config = persettings.config[currentGame.titleId] ?? self.config
        
        controllerManager.registerControllerTypeForMatchingControllers()
        config.gamepath = currentGame.fileURL.path
        config.inputids = Array(Set(controllerManager.selectedControllers))
        
        if config.inputids.isEmpty {
            config.inputids.append("0")
        }
        
        print(config.inputids)
        configureEnvironmentVariables()
        
        do {
            try ryujinx.start(with: config)
        } catch {
            print("Failed to start game '\(currentGame.titleId)': \(error)")
        }
    }
    
    private func configureEnvironmentVariables() {
        let useDualMappedJIT: Bool
        if #available(iOS 19, *) {
            useDualMappedJIT = nativeSettings.setting(forKey: "DUAL_MAPPED_JIT", default: true).value
        } else {
            useDualMappedJIT = nativeSettings.setting(forKey: "DUAL_MAPPED_JIT", default: false).value
        }
        
        if useDualMappedJIT {
            setenv("DUAL_MAPPED_JIT", "1", 1)
            Self.succeededJIT = RyujinxBridge.initialize_dualmapped()
        } else {
            setenv("DUAL_MAPPED_JIT", "0", 1)
        }
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", 1)
            return
        }
        
        let supportsArgumentBuffersTier2 = device.argumentBuffersSupport.rawValue >= MTLArgumentBuffersTier.tier2.rawValue
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", supportsArgumentBuffersTier2 ? "1" : "0", 1)
    }
}
