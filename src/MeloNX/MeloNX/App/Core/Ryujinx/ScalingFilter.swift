//
//  ScalingFilter.swift
//  MeloNX
//

import Foundation

/// Mirrors Ryujinx.Common.Configuration.ScalingFilter (src/Ryujinx.Common/Configuration/ScalingFilter.cs)
/// — the core's own enum, not invented here. The core also has `.Nearest`
/// and (GAL-side only) `.Area`, but MeloNX only exposes the options that
/// make sense as a user-facing "Upscaling" choice: the existing implicit
/// behavior (Bilinear), FSR, and (FASE 3 POC, off by default) MetalFX
/// Spatial. Raw values match the C# enum's member names exactly —
/// CommandLineParser (used by Ryujinx.Headless.SDL2.Options) parses
/// --scaling-filter by name.
public enum ScalingFilter: String, Codable, CaseIterable {
    case bilinear = "Bilinear"
    case fsr = "Fsr"
    case metalFxSpatial = "MetalFxSpatial"

    var displayName: String {
        switch self {
        case .bilinear: return "Original"
        case .fsr: return "FSR"
        case .metalFxSpatial: return "MetalFX Spatial"
        }
    }

    /// True on the real, confirmed-implemented MetalFX interop path (see
    /// MetalFxCapabilityInspector's device/OS gate) - false everywhere
    /// else, matching requirement #5's "MetalFX debe permanecer desactivado
    /// por defecto": the Settings picker only lists this case when the
    /// user's own device plausibly supports it AND still lets the native
    /// side veto it per-frame via the real availability/fallback logic in
    /// MetalFxSpatialScalingFilter.cs.
    static var isMetalFxSpatialExperimental: Bool { true }
}
