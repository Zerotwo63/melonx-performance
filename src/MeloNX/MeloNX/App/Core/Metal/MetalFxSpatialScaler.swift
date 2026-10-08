//
//  MetalFxSpatialScaler.swift
//  MeloNX
//

import Metal
import MetalFX

/// Native bridge for Ryujinx.Graphics.Vulkan.MetalInterop.MetalFxNative's
/// P/Invoke declarations (FASE 3 POC, this round). The C# side exports a
/// Vulkan offscreen texture's backing MTLTexture via VK_EXT_metal_objects
/// (confirmed genuinely implemented in the bundled MoltenVK binary and
/// bound by Silk.NET 2.21.0 - see
/// Ryujinx.Graphics.Vulkan/Effects/MetalFxSpatialScalingFilter.cs's doc
/// comment for the full chain), hands this file the raw pointer, and this
/// file runs the real MTLFXSpatialScaler against it.
///
/// LIFETIME: the raw pointers received here are NOT retained
/// (Unmanaged...takeUnretainedValue()) - safe only because the C# caller
/// keeps its own TextureView/Auto<T> reference alive for the entire
/// duration of the call into this file, which keeps MoltenVK's underlying
/// MTLTexture wrapper alive too. Never cache these pointers across calls.
///
/// SYNCHRONIZATION: scale(...) is intentionally synchronous -
/// commandBuffer.waitUntilCompleted() blocks until Metal's GPU work is
/// done before this function returns control to C#. See
/// MetalFxSpatialScalingFilter.cs's doc comment for why a CPU-side
/// blocking wait was chosen over a cross-API MTLSharedEvent semaphore for
/// this first implementation (correctness-by-construction over
/// pipelining).
///
/// NOT YET VERIFIED ON A REAL DEVICE: this compiles (if CI confirms)
/// against real MetalFX/Metal API shapes to the best of available
/// knowledge, but no Metal or Vulkan context exists in this build
/// environment to actually run it. Do not report this as "working" from
/// a CI-green result alone.
enum MetalFxSpatialScaler {
    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    private static var scaler: Any?
    private static var scalerInputSize: (Int, Int) = (0, 0)
    private static var scalerOutputSize: (Int, Int) = (0, 0)
    private static var scalerPixelFormats: (MTLPixelFormat, MTLPixelFormat)?

    static func isAvailable() -> Bool {
        guard commandQueue != nil else { return false }
        guard let capability = MetalFXCapabilityInspector.current() else { return false }
        return capability.supportsSpatialScaling
    }

    @available(iOS 16.0, *)
    private static func ensureScaler(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        inputFormat: MTLPixelFormat,
        outputFormat: MTLPixelFormat
    ) -> MTLFXSpatialScaler? {
        if let existing = scaler as? MTLFXSpatialScaler,
           scalerInputSize == (inputWidth, inputHeight),
           scalerOutputSize == (outputWidth, outputHeight),
           scalerPixelFormats?.0 == inputFormat,
           scalerPixelFormats?.1 == outputFormat {
            return existing
        }

        guard let device else { return nil }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = inputFormat
        descriptor.outputTextureFormat = outputFormat

        guard let newScaler = descriptor.makeSpatialScaler(device: device) else {
            return nil
        }

        scaler = newScaler
        scalerInputSize = (inputWidth, inputHeight)
        scalerOutputSize = (outputWidth, outputHeight)
        scalerPixelFormats = (inputFormat, outputFormat)

        return newScaler
    }

    static func scale(
        inputPtr: UnsafeMutableRawPointer?,
        outputPtr: UnsafeMutableRawPointer?,
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        guard let commandQueue else { return false }
        guard let inputPtr, let outputPtr else { return false }
        guard inputWidth > 0, inputHeight > 0, outputWidth > 0, outputHeight > 0 else { return false }

        let inputObject = Unmanaged<AnyObject>.fromOpaque(inputPtr).takeUnretainedValue()
        let outputObject = Unmanaged<AnyObject>.fromOpaque(outputPtr).takeUnretainedValue()

        guard let inputTexture = inputObject as? MTLTexture,
              let outputTexture = outputObject as? MTLTexture else {
            return false
        }

        guard let scaler = ensureScaler(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            inputFormat: inputTexture.pixelFormat,
            outputFormat: outputTexture.pixelFormat
        ) else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return commandBuffer.status == .completed
    }
}

private var metalFxFramesProcessed: Int64 = 0

@_cdecl("metalfx_is_available")
public func metalfx_is_available() -> UInt8 {
    MetalFxSpatialScaler.isAvailable() ? 1 : 0
}

@_cdecl("metalfx_scale")
public func metalfx_scale(
    inputMtlTexture: UnsafeMutableRawPointer?,
    outputMtlTexture: UnsafeMutableRawPointer?,
    inputWidth: Int32,
    inputHeight: Int32,
    outputWidth: Int32,
    outputHeight: Int32
) -> UInt8 {
    let ok = MetalFxSpatialScaler.scale(
        inputPtr: inputMtlTexture,
        outputPtr: outputMtlTexture,
        inputWidth: Int(inputWidth),
        inputHeight: Int(inputHeight),
        outputWidth: Int(outputWidth),
        outputHeight: Int(outputHeight)
    )
    return ok ? 1 : 0
}

/// Requirement #8: a real, independent counter of frames MetalFX actually
/// processed - only incremented by MetalFxSpatialScalingFilter.cs AFTER
/// metalfx_scale() returned success, never on construction/availability
/// alone. Read by Settings/diagnostics UI via metalfx_frames_processed().
@_cdecl("metalfx_report_frame_processed")
public func metalfx_report_frame_processed() {
    metalFxFramesProcessed += 1
}

@_cdecl("metalfx_frames_processed")
public func metalfx_frames_processed() -> Int64 {
    metalFxFramesProcessed
}
