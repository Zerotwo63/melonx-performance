using NUnit.Framework;
using System;
using CommonScalingFilter = Ryujinx.Common.Configuration.ScalingFilter;
using GalScalingFilter = Ryujinx.Graphics.GAL.ScalingFilter;

namespace Ryujinx.Tests.Graphics.Vulkan
{
    /// <summary>
    /// Regression guard for the FASE 3 MetalFX Spatial POC round: adding
    /// ScalingFilter.MetalFxSpatial to BOTH
    /// Ryujinx.Common.Configuration.ScalingFilter and
    /// Ryujinx.Graphics.GAL.ScalingFilter only works correctly because
    /// WindowBase.SetScalingFilter() converts between them with a direct
    /// enum-value cast:
    /// `Renderer?.Window.SetScalingFilter((Graphics.GAL.ScalingFilter)ScalingFilter)`
    /// (src/Ryujinx.Headless.SDL2/WindowBase.cs). That cast is only correct
    /// for values whose ordinals match in both enums - GAL's enum has an
    /// extra GAL-only value (Area) that Common's enum deliberately skips,
    /// which is exactly the kind of mismatch that silently breaks this
    /// cast if a future addition isn't pinned carefully. This test does
    /// not exercise WindowBase itself (no Vulkan device available in
    /// CI/here) - it only proves the two enums stay numerically aligned
    /// for every value Common actually exposes.
    /// </summary>
    class ScalingFilterOrdinalTests
    {
        [TestCase(CommonScalingFilter.Bilinear, GalScalingFilter.Bilinear)]
        [TestCase(CommonScalingFilter.Nearest, GalScalingFilter.Nearest)]
        [TestCase(CommonScalingFilter.Fsr, GalScalingFilter.Fsr)]
        [TestCase(CommonScalingFilter.MetalFxSpatial, GalScalingFilter.MetalFxSpatial)]
        public void CommonValueCastsToExpectedGalValue(CommonScalingFilter commonValue, GalScalingFilter expectedGalValue)
        {
            var castValue = (GalScalingFilter)commonValue;

            Assert.That(castValue, Is.EqualTo(expectedGalValue));
        }

        [Test]
        public void EveryCommonValueHasAMatchingGalName()
        {
            foreach (CommonScalingFilter commonValue in Enum.GetValues(typeof(CommonScalingFilter)))
            {
                var castValue = (GalScalingFilter)commonValue;

                Assert.That(
                    Enum.IsDefined(typeof(GalScalingFilter), castValue),
                    $"Common.ScalingFilter.{commonValue} (ordinal {(int)commonValue}) casts to an undefined Graphics.GAL.ScalingFilter ordinal.");

                Assert.That(
                    castValue.ToString(),
                    Is.EqualTo(commonValue.ToString()),
                    $"Common.ScalingFilter.{commonValue} casts to Graphics.GAL.ScalingFilter.{castValue} - names must match or WindowBase's cast is silently wrong.");
            }
        }
    }
}
