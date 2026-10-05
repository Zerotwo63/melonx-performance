//
//  MetalFXCapabilityInspector.swift
//  MeloNX
//

import Metal
import MetalFX

/// Real device capability check for MetalFX upscaling —
/// MTLFXSpatialScalerDescriptor / MTLFXTemporalScalerDescriptor. Despite
/// MeloNX's 18.1 deployment target comfortably exceeding both APIs'
/// stated iOS 16/17 minimums, the compiler still required an explicit
/// #available guard here (confirmed by a real build failure, not
/// assumed from the doc comment that used to be here claiming the
/// guard was dead weight — that assumption was wrong for this specific
/// pair of symbols, unlike the iOS 17.4 case elsewhere in this fork).
///
/// This is informational only — it does not perform any upscaling.
/// Genuine MetalFX integration needs to intercept the rendered frame
/// *before* it's presented, replacing the implicit bilinear scale Core
/// Animation already does when a CAMetalLayer's drawable size (set by
/// --resolution-scale) differs from its bounds. That interception point
/// lives entirely inside the native Vulkan/MoltenVK swapchain code
/// (C#/.NET, outside this tree) — confirmed by reading MeloMTKView.swift
/// and MetalViewContainer.swift, neither of which implements
/// MTKViewDelegate/draw(in:) or touches a frame at all; MeloMTKView is
/// purely touch-input handling, and RyujinxBridge.setNativeWindow(_:)
/// hands the native core the CAMetalLayer directly. There is no Swift-side
/// hook to attach an MTLFXSpatialScaler/MTLFXTemporalScaler pass to.
/// MetalFX.framework wasn't linked anywhere in the project before this
/// file either (checked project.pbxproj).
enum MetalFXCapabilityInspector {
    struct Capability {
        let supportsSpatialScaling: Bool
        let supportsTemporalScaling: Bool
    }

    static func current() -> Capability? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        guard #available(iOS 16.0, *) else { return nil }

        return Capability(
            supportsSpatialScaling: MTLFXSpatialScalerDescriptor.supportsDevice(device),
            supportsTemporalScaling: MTLFXTemporalScalerDescriptor.supportsDevice(device)
        )
    }
}
