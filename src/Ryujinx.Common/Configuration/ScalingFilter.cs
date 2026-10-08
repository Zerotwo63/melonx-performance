using Ryujinx.Common.Utilities;
using System.Text.Json.Serialization;

namespace Ryujinx.Common.Configuration
{
    [JsonConverter(typeof(TypedStringEnumConverter<ScalingFilter>))]
    public enum ScalingFilter
    {
        Bilinear,
        Nearest,
        Fsr,
        // 3 deliberately skipped: Ryujinx.Graphics.GAL.ScalingFilter already
        // uses ordinal 3 for Area, a GAL-internal-only value this config
        // enum never exposed. WindowBase.SetScalingFilter() casts this enum
        // directly to the GAL one by ordinal value
        // ((Graphics.GAL.ScalingFilter)ScalingFilter) - MetalFxSpatial is
        // pinned to 4 here and in the GAL enum so that cast keeps mapping to
        // the correct value instead of accidentally landing on Area.
        MetalFxSpatial = 4,
    }
}
