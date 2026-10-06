//
//  MetalView.swift
//  MeloNX
//
//  Created by Stossy11 on 09/02/2025.
//

import SwiftUI
import MetalKit
import Metal

struct MetalView: UIViewRepresentable {
    var airplay: Bool = Air.shared.connected // just in case :3
    
    func makeUIView(context: Context) -> UIView {
        return Self.createView()
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // nothin
    }
    
    @discardableResult
    static func createView() -> UIView {
        if Ryujinx.shared.emulationUIView == nil {
            let view = MeloMTKView()

            guard let metalLayer = view.layer as? CAMetalLayer else {
                fatalError("[Swift] Error: MTKView's layer is not a CAMetalLayer")
            }

            UIApplication.shared.isIdleTimerDisabled = true

            //metalLayer.presentsWithTransaction = false
            //metalLayer.allowsNextDrawableTimeout = false


            let framesSelector = NSSelectorFromString("setNominalFramesPerSecond:")

            if metalLayer.responds(to: framesSelector) {
                metalLayer.perform(framesSelector, with: 60 as NSNumber)
            }

            let setterSelector = NSSelectorFromString("setDisplaySyncEnabled:")

            if metalLayer.responds(to: setterSelector) {
                metalLayer.perform(setterSelector, with: NSNumber(value: false))
            }

            notnil(metalLayer.device) ? () : (metalLayer.device = MTLCreateSystemDefaultDevice())

            let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()

            // Real values, not just "success" - createView() is called
            // directly by LaunchGameHandler BEFORE SwiftUI necessarily
            // finishes inserting this view into the real window hierarchy
            // via EmulationView's own MetalView, so the layer's bounds/
            // drawableSize here could legitimately still be zero. This is
            // exactly the evidence needed before touching anything.
            BootDiagnostics.shared.log("MetalView ptr", result: "\(Unmanaged.passUnretained(view).toOpaque())")
            BootDiagnostics.shared.log("CAMetalLayer ptr", result: "\(layerPtr)")
            BootDiagnostics.shared.log("bounds", result: "\(metalLayer.bounds.width)x\(metalLayer.bounds.height)")
            BootDiagnostics.shared.log("drawableSize", result: "\(metalLayer.drawableSize.width)x\(metalLayer.drawableSize.height)")
            BootDiagnostics.shared.log("contentScaleFactor", result: "\(metalLayer.contentsScale)")
            BootDiagnostics.shared.log("window handle", result: view.window.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? "nil (not yet in a window)")

            RyujinxBridge.setNativeWindow(layerPtr)
            BootDiagnostics.shared.log("surface handle (native window set)", result: "\(layerPtr)")

            Ryujinx.shared.emulationUIView = view
            Ryujinx.shared.metalLayer = metalLayer
            return view
        }

        return Ryujinx.shared.emulationUIView!
    }
}
