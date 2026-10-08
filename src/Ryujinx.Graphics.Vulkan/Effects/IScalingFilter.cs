using Silk.NET.Vulkan;
using System;
using Extent2D = Ryujinx.Graphics.GAL.Extents2D;

namespace Ryujinx.Graphics.Vulkan.Effects
{
    internal interface IScalingFilter : IDisposable
    {
        float Level { get; set; }

        /// <summary>
        /// Returns the CommandBufferScoped the caller should continue
        /// recording into - normally the same <paramref name="cbs"/> passed
        /// in, unchanged. MetalFxSpatialScalingFilter is the one
        /// implementation that needs to flush/retire the current command
        /// buffer mid-Run() (to get a real CPU-side completion guarantee
        /// before handing texture data to Metal) and rent a fresh one, so
        /// the return value exists for that case - every other
        /// implementation just returns <paramref name="cbs"/> as-is.
        /// </summary>
        CommandBufferScoped Run(
            TextureView view,
            CommandBufferScoped cbs,
            Auto<DisposableImageView> destinationTexture,
            Image destinationImage,
            Format format,
            int width,
            int height,
            Extent2D source,
            Extent2D destination);
    }
}
