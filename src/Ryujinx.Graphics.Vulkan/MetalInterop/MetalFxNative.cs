using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Vulkan.MetalInterop
{
    /// <summary>
    /// P/Invoke declarations for the Swift-side MetalFX bridge
    /// (MeloNX/App/Core/Metal/MetalFxSpatialScaler.swift's @_cdecl exports).
    ///
    /// "__Internal" is the standard iOS/Xamarin-style pseudo-library name
    /// meaning "resolve this symbol from the current process image" - valid
    /// here because the whole app (Swift UI layer + this .NET backend) is
    /// statically linked into one iOS binary, the same reason the EXISTING
    /// reverse-direction calls (Swift calling into C# via
    /// [UnmanagedCallersOnly] exports in Ryujinx.Headless.SDL2/Program.cs,
    /// e.g. get_gpu_fifo_percent) already work without a dynamic library to
    /// load. This is a different, independent symbol resolution direction
    /// (C# calling Swift) using the same "__Internal" mechanism, not
    /// something invented for this feature.
    ///
    /// Every method here can fail to resolve, throw, or behave incorrectly
    /// on a device - none of this has been exercised outside a CI compile
    /// check in this environment. See MetalFxSpatialScalingFilter.cs's doc
    /// comment for the full disclosure.
    /// </summary>
    internal static class MetalFxNative
    {
        [DllImport("__Internal", EntryPoint = "metalfx_is_available")]
        private static extern byte metalfx_is_available();

        [DllImport("__Internal", EntryPoint = "metalfx_scale")]
        private static extern byte metalfx_scale(
            nint inputMtlTexture,
            nint outputMtlTexture,
            int inputWidth,
            int inputHeight,
            int outputWidth,
            int outputHeight);

        [DllImport("__Internal", EntryPoint = "metalfx_report_frame_processed")]
        private static extern void metalfx_report_frame_processed(int sourceWidth, int sourceHeight, int outputWidth, int outputHeight);

        [DllImport("__Internal", EntryPoint = "metalfx_report_frame_attempt")]
        private static extern void metalfx_report_frame_attempt();

        [DllImport("__Internal", EntryPoint = "metalfx_report_frame_fallback")]
        private static extern void metalfx_report_frame_fallback();

        [DllImport("__Internal", EntryPoint = "metalfx_set_effective_filter")]
        private static extern void metalfx_set_effective_filter(int code);

        /// <summary>
        /// True only if MTLFXSpatialScalerDescriptor.supported is true for
        /// the real device AND iOS reports a version MetalFX requires
        /// (iOS 16+) - both checked on the Swift side, see
        /// metalfx_is_available()'s implementation. Never assumed true just
        /// because this binary happened to link successfully.
        /// </summary>
        public static bool IsAvailable()
        {
            try
            {
                return metalfx_is_available() != 0;
            }
            catch
            {
                // The symbol itself failing to resolve (e.g. an
                // out-of-sync native build) must not crash the emulator -
                // treat it exactly like "unavailable".
                return false;
            }
        }

        /// <summary>
        /// Blocks (CPU-side) until Metal's command buffer for this scale
        /// has completed - see MetalFxSpatialScalingFilter's doc comment
        /// for why this method is synchronous rather than using a
        /// cross-API semaphore. Returns false on ANY failure (scaler
        /// creation failed, encode failed, device lost, etc) - the caller
        /// is required to fall back to a plain blit when this returns
        /// false.
        /// </summary>
        public static bool Scale(nint inputMtlTexture, nint outputMtlTexture, int inputWidth, int inputHeight, int outputWidth, int outputHeight)
        {
            try
            {
                return metalfx_scale(inputMtlTexture, outputMtlTexture, inputWidth, inputHeight, outputWidth, outputHeight) != 0;
            }
            catch
            {
                return false;
            }
        }

        // All telemetry calls are diagnostics-only. Never throw from a
        // missing Swift symbol or let telemetry break an otherwise valid frame.
        public static void ReportFrameAttempt()
        {
            try { metalfx_report_frame_attempt(); } catch { }
        }

        public static void ReportFrameFallback()
        {
            try { metalfx_report_frame_fallback(); } catch { }
        }

        // Codes are defined alongside the Swift exporter; 5 means a
        // MetalFX filter was constructed, NOT that it processed a frame.
        public static void ReportEffectiveFilter(int code)
        {
            try { metalfx_set_effective_filter(code); } catch { }
        }

        public static void ReportFrameProcessed(int sourceWidth, int sourceHeight, int outputWidth, int outputHeight)
        {
            try
            {
                metalfx_report_frame_processed(sourceWidth, sourceHeight, outputWidth, outputHeight);
            }
            catch
            {
                // Metrics never affect the frame that already succeeded.
            }
        }
    }
}
