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
/// UPDATE (FASE 3 round): the claim below that there is "no Swift-side
/// hook" is now OUTDATED — a real one exists via VK_EXT_metal_objects
/// (confirmed genuinely implemented in the bundled MoltenVK binary and
/// bound by Silk.NET 2.21.0 this round, see
/// Ryujinx.Graphics.Vulkan/Effects/MetalFxSpatialScalingFilter.cs). This
/// struct's `current()` is now reused directly by
/// Metal/MetalFxSpatialScaler.swift's metalfx_is_available() as the
/// device/OS capability gate for that path. Kept rather than duplicated.
///
/// Still accurate: `current()` alone is informational and performs no
/// upscaling by itself — MeloMTKView/MetalViewContainer remain
/// touch-input-only, and the actual interop happens entirely on the
/// native (C#/Vulkan) side exporting a VkImage's backing MTLTexture, not
/// through a Core Animation/MTKView draw hook.
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
