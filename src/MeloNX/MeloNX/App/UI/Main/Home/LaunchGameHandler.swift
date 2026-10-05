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
        isGameReady && hasJITEntitlement
    }
    
    var shouldShowEntitlement: Bool {
        // Surface the signing/provisioning problem immediately. The previous
        // condition depended on isGameReady, which itself requires JIT. When
        // both JIT and the memory entitlement were missing, neither the JIT
        // sheet nor the entitlement alert could appear, so tapping a game
        // looked like a no-op.
        currentGame != nil && !hasJITEntitlement
    }
    
    var shouldShowPopover: Bool {
        currentGame != nil
            && ryujinx.jitenabled
            && !profileSelected
            && nativeSettings.showProfileonGame.value
            && hasJITEntitlement
    }
    
    var shouldCheckJIT: Bool {
        currentGame != nil
            && !ryujinx.jitenabled
            && !(nativeSettings.ignoreJIT.value as Bool)
            && hasJITEntitlement
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
            } else if self.nativeSettings.builtInStikJIT.value {
                MeloNXBuiltInJIT.enableCurrentProcess()
            } else {
                print("[JIT] no fallback available")

                // ContentView also probes JIT on app launch while no game is
                // selected. Avoid showing an error there; only explain the
                // blocker when the user actually tried to start a game.
                if self.currentGame != nil {
                    presentAlert(
                        title: "JIT Not Acquired",
                        message: "MeloNX could not acquire JIT with the internal JitStreamer path, and no fallback JIT method is enabled. Configure a working JIT method before launching the game."
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
