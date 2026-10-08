namespace Ryujinx.Graphics.GAL
{
    public enum ScalingFilter
    {
        Bilinear,
        Nearest,
        Fsr,
        Area,
        // Pinned to 4, matching Ryujinx.Common.Configuration.ScalingFilter's
        // MetalFxSpatial - see that enum's comment for why the ordinal must
        // stay aligned (WindowBase.SetScalingFilter's direct enum cast).
        MetalFxSpatial,
    }
}
