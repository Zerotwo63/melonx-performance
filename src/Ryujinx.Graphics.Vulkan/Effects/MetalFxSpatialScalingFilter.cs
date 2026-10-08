using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan.MetalInterop;
using Silk.NET.Vulkan;
using System;
using Extent2D = Ryujinx.Graphics.GAL.Extents2D;
using Format = Silk.NET.Vulkan.Format;

namespace Ryujinx.Graphics.Vulkan.Effects
{
    /// <summary>
    /// FASE 3 POC (explicit user request, this round) - MetalFX Spatial
    /// upscaling via VK_EXT_metal_objects. Disabled by default; only
    /// reachable when the user explicitly selects "MetalFX Spatial" in
    /// Settings (ScalingFilter.MetalFxSpatial).
    ///
    /// ARCHITECTURE: VK_EXT_metal_objects can only export the backing
    /// MTLTexture of a VkImage that was CREATED with
    /// VkExportMetalObjectCreateInfoEXT chained into VkImageCreateInfo -
    /// it cannot be retrofitted onto an already-existing image. The game's
    /// real offscreen render target (<paramref name="view"/> in Run()) and
    /// the swapchain image are both part of the STABLE path and were not
    /// created that way, and per this round's explicit instruction that
    /// path must stay untouched. So this filter owns two PRIVATE "bridge"
    /// textures (_inputBridge/_outputBridge), created exportable from the
    /// start, and uses plain Vulkan blits (TextureCopy.Blit, the same
    /// helper TextureView's own copy paths already use) to move pixels
    /// in and out of them. This costs two extra blits per frame versus a
    /// hypothetical true zero-copy path, which is the honest trade-off of
    /// not touching the stable texture-creation code.
    ///
    /// SYNCHRONIZATION (requirement #4): rather than a cross-API
    /// MTLSharedEvent semaphore handshake (the more "proper" GPU-pipelined
    /// approach, but a second large source of unverifiable risk on top of
    /// everything else here), this POC uses a simpler, strictly correct
    /// CPU-side double fence wait: flush + wait for the Vulkan copy-in to
    /// finish completely (same _gd.FlushAllCommands()/cbs.GetFence().Wait()
    /// pattern Window.cs itself already uses for screen capture) before
    /// handing the texture to Metal, and the native Metal call blocks on
    /// MTLCommandBuffer.waitUntilCompleted() before returning, so the
    /// copy-out is only ever recorded after Metal's write is provably done.
    /// This trades GPU pipelining/overlap for correctness-by-construction -
    /// disclosed explicitly as a performance cost, not a shortcut on
    /// safety: there is no path through this class that reads a texture
    /// before its writer's completion has been observed.
    ///
    /// FAILURE HANDLING (requirement #6): the constructor throws if the
    /// extension wasn't enabled (Window.cs's factory catches this and
    /// falls back to bilinear - see UpdateEffect()). Within Run() itself,
    /// any failure (export failure, native bridge unavailable/failed) logs
    /// and falls back to a plain blit of view straight into the
    /// destination for that frame, matching exactly what Window.cs's own
    /// "no filter" path already does - the destination is never left
    /// undefined.
    ///
    /// WHAT THIS DOES NOT PROVE: compiling cleanly (CI) only confirms the
    /// C# type/field names used here match the real, confirmed-present
    /// Silk.NET 2.21.0 bindings. It proves nothing about runtime
    /// correctness - texture format/usage compatibility with MoltenVK's
    /// actual export implementation, Metal command buffer completion
    /// timing, or visual output - none of which can be exercised without a
    /// real iOS device and Metal-capable GPU. This must not be reported as
    /// "working" until verified on one.
    /// </summary>
    internal class MetalFxSpatialScalingFilter : IScalingFilter
    {
        private readonly VulkanRenderer _gd;
        private readonly Device _device;

        private TextureView _inputBridge;
        private TextureView _outputBridge;

        private long _framesAttempted;
        private long _framesSucceeded;
        private long _framesFallenBack;

        public float Level { get; set; }

        public MetalFxSpatialScalingFilter(VulkanRenderer gd, Device device)
        {
            if (!gd.SupportsMetalObjectsExport)
            {
                throw new NotSupportedException("VK_EXT_metal_objects was not enabled on this device - MetalFX Spatial interop is unavailable.");
            }

            if (!MetalFxNative.IsAvailable())
            {
                throw new NotSupportedException("The native MetalFX bridge reports MTLFXSpatialScaler is unavailable on this device/OS version.");
            }

            _gd = gd;
            _device = device;
        }

        public void Dispose()
        {
            _inputBridge?.Dispose();
            _outputBridge?.Dispose();
            _inputBridge = null;
            _outputBridge = null;
        }

        private void EnsureBridgeTextures(TextureCreateInfo sourceInfo, int outWidth, int outHeight)
        {
            if (_inputBridge == null
                || _inputBridge.Width != sourceInfo.Width
                || _inputBridge.Height != sourceInfo.Height
                || !_inputBridge.Info.Format.Equals(sourceInfo.Format))
            {
                _inputBridge?.Dispose();

                var inputInfo = new TextureCreateInfo(
                    sourceInfo.Width,
                    sourceInfo.Height,
                    sourceInfo.Depth,
                    1,
                    sourceInfo.Samples,
                    sourceInfo.BlockWidth,
                    sourceInfo.BlockHeight,
                    sourceInfo.BytesPerPixel,
                    sourceInfo.Format,
                    sourceInfo.DepthStencilMode,
                    sourceInfo.Target,
                    sourceInfo.SwizzleR,
                    sourceInfo.SwizzleG,
                    sourceInfo.SwizzleB,
                    sourceInfo.SwizzleA);

                var storage = new TextureStorage(_gd, _device, inputInfo, exportableToMetal: true);
                _inputBridge = storage.CreateView(inputInfo, 0, 0);
            }

            if (_outputBridge == null
                || _outputBridge.Width != outWidth
                || _outputBridge.Height != outHeight
                || !_outputBridge.Info.Format.Equals(sourceInfo.Format))
            {
                _outputBridge?.Dispose();

                var outputInfo = new TextureCreateInfo(
                    outWidth,
                    outHeight,
                    sourceInfo.Depth,
                    1,
                    sourceInfo.Samples,
                    sourceInfo.BlockWidth,
                    sourceInfo.BlockHeight,
                    sourceInfo.BytesPerPixel,
                    sourceInfo.Format,
                    sourceInfo.DepthStencilMode,
                    sourceInfo.Target,
                    sourceInfo.SwizzleR,
                    sourceInfo.SwizzleG,
                    sourceInfo.SwizzleB,
                    sourceInfo.SwizzleA);

                var storage = new TextureStorage(_gd, _device, outputInfo, exportableToMetal: true);
                _outputBridge = storage.CreateView(outputInfo, 0, 0);
            }
        }

        public unsafe CommandBufferScoped Run(
            TextureView view,
            CommandBufferScoped cbs,
            Auto<DisposableImageView> destinationTexture,
            Image destinationImage,
            Format format,
            int width,
            int height,
            Extent2D source,
            Extent2D destination)
        {
            _framesAttempted++;

            try
            {
                EnsureBridgeTextures(view.Info, width, height);

                var srcImage = view.GetImage().Get(cbs).Value;
                var inputBridgeImage = _inputBridge.GetImage().Get(cbs).Value;
                var outputBridgeImage = _outputBridge.GetImage().Get(cbs).Value;

                // Copy the real render target into our exportable input
                // bridge. Same helper TextureView's own copy paths use.
                TextureCopy.Blit(
                    _gd.Api,
                    cbs.CommandBuffer,
                    srcImage,
                    inputBridgeImage,
                    view.Info,
                    _inputBridge.Info,
                    source,
                    new Extent2D(0, 0, _inputBridge.Width, _inputBridge.Height),
                    0, 0, 0, 0, 1, 1,
                    linearFilter: false);

                // Flush and block (CPU-side) until the copy-in above is
                // 100% complete on the GPU - see this class's doc comment
                // for why this, and not a cross-API semaphore, is used
                // here. Only after this wait returns is it provably safe
                // to hand the input bridge's memory to Metal.
                _gd.FlushAllCommands();
                cbs.GetFence().Wait();

                // Single fresh command buffer: used both to register these
                // bridge images as "in use" for the Metal export calls
                // below, and as the command buffer the rest of this method
                // (and ultimately the caller) continues recording into.
                cbs = _gd.CommandBufferPool.Rent();

                nint inputMtlTexture = ExportAsMetalTexture(_inputBridge, cbs);
                nint outputMtlTexture = ExportAsMetalTexture(_outputBridge, cbs);

                bool scaled = inputMtlTexture != 0 && outputMtlTexture != 0 && MetalFxNative.Scale(
                    inputMtlTexture,
                    outputMtlTexture,
                    _inputBridge.Width,
                    _inputBridge.Height,
                    _outputBridge.Width,
                    _outputBridge.Height);

                if (!scaled)
                {
                    _framesFallenBack++;
                    Logger.Warning?.Print(LogClass.Gpu, "MetalFX Spatial failed to process this frame, falling back to a direct blit.");

                    TextureCopy.Blit(
                        _gd.Api,
                        cbs.CommandBuffer,
                        srcImage,
                        destinationImage,
                        view.Info,
                        view.Info,
                        source,
                        destination,
                        0, 0, 0, 0, 1, 1,
                        linearFilter: true);

                    return cbs;
                }

                _framesSucceeded++;
                MetalFxNative.ReportFrameProcessed();

                // Metal's write into the output bridge is already
                // guaranteed complete (MetalFxNative.Scale blocks on
                // waitUntilCompleted() before returning), so this copy-out
                // can be recorded immediately with no further wait.
                TextureCopy.Blit(
                    _gd.Api,
                    cbs.CommandBuffer,
                    outputBridgeImage,
                    destinationImage,
                    _outputBridge.Info,
                    view.Info,
                    new Extent2D(0, 0, _outputBridge.Width, _outputBridge.Height),
                    destination,
                    0, 0, 0, 0, 1, 1,
                    linearFilter: false);

                return cbs;
            }
            catch (Exception ex)
            {
                _framesFallenBack++;
                Logger.Warning?.Print(LogClass.Gpu, $"MetalFX Spatial threw while processing a frame, falling back to a direct blit: {ex.Message}");

                // Whatever cbs currently holds at this point (the original
                // parameter, or a freshly-rented one from further down this
                // method) is always a valid, currently-open command buffer
                // - every reassignment above only happens after the
                // previous one was safely flushed/retired first.
                try
                {
                    var srcImage = view.GetImage().Get(cbs).Value;

                    TextureCopy.Blit(
                        _gd.Api,
                        cbs.CommandBuffer,
                        srcImage,
                        destinationImage,
                        view.Info,
                        view.Info,
                        source,
                        destination,
                        0, 0, 0, 0, 1, 1,
                        linearFilter: true);
                }
                catch
                {
                    // If even the fallback blit fails, there is nothing
                    // further we can safely do here - surfacing the
                    // original exception would be misleading since the
                    // frame is genuinely unrecoverable at this point.
                }

                return cbs;
            }
        }

        private unsafe nint ExportAsMetalTexture(TextureView bridge, CommandBufferScoped cbs)
        {
            var image = bridge.GetImage().Get(cbs).Value;

            var textureInfo = new ExportMetalTextureInfoEXT
            {
                SType = StructureType.ExportMetalTextureInfoExt,
                Image = image,
                Plane = ImageAspectFlags.ColorBit,
            };

            var objectsInfo = new ExportMetalObjectsInfoEXT
            {
                SType = StructureType.ExportMetalObjectsInfoExt,
                PNext = &textureInfo,
            };

            _gd.MetalObjectsApi.ExportMetalObjects(_device, &objectsInfo);

            return (nint)textureInfo.MtlTexture;
        }

        /// <summary>
        /// Diagnostics (requirement #8): real counters, not just "did the
        /// constructor succeed" - distinguishes frames MetalFX genuinely
        /// processed from ones that fell back. Read by the native bridge's
        /// own diagnostic exports so Swift/Settings can show these without
        /// a second plumbing path.
        /// </summary>
        public (long attempted, long succeeded, long fallenBack) GetDiagnostics() =>
            (_framesAttempted, _framesSucceeded, _framesFallenBack);
    }
}
