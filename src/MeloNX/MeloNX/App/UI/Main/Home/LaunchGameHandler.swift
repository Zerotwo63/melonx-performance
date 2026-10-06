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
        print("[JIT] activation requested")
        print("Has TXM? \(ProcessInfo.processInfo.hasTXM)")

        guard !ryujinx.jitenabled else { return }

        gametorunDate = "\(Date().timeIntervalSince1970)"
        gametorun = currentGame?.titleId ?? ""

        Task { @MainActor in
            let acquired = await JITStreamerEB.attach()

            guard !acquired else { return }

            print("[JIT] fallback selected")

            if self.nativeSettings.useTrollStore.value {
                askForJIT()
            } else if self.nativeSettings.stikJIT.value {
                enableJITStik()
            } else if BuiltInStikJITAvailability.isAvailable {
                // If the embedded helper is usable, prefer it automatically.
                // Requiring the user to discover and toggle it first made the
                // "no third app" path effectively unreachable.
                self.nativeSettings.builtInStikJIT.value = true
                MeloNXBuiltInJIT.enableCurrentProcess()
            } else {
                print("[JIT] no fallback available")

                if self.currentGame != nil {
                    let reason: String
                    switch BuiltInStikJITAvailability.unavailableReason() {
                    case .missingGetTaskAllow:
                        reason = "this AltStore signature does not include get-task-allow"
                    case .runningInLiveContainer:
                        reason = "MeloNX is running inside LiveContainer"
                    case .noPairingFileImported:
                        reason = "no pairing file has been imported for the built-in JIT helper"
                    case .helperMissing:
                        reason = "the MeloNX JIT helper extension is missing from this installation"
                    case .none:
                        reason = "the built-in JIT helper could not be started"
                    }

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
