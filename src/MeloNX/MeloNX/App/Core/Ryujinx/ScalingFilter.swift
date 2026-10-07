//
//  ScalingFilter.swift
//  MeloNX
//

import Foundation

/// Mirrors Ryujinx.Common.Configuration.ScalingFilter (src/Ryujinx.Common/Configuration/ScalingFilter.cs)
/// — the core's own enum, not invented here. The core also has `.Nearest`
/// and (GAL-side only) `.Area`, but MeloNX only exposes the two options
/// that make sense as a user-facing "Upscaling" choice: the existing
/// implicit behavior (Bilinear) and FSR. Raw values match the C# enum's
/// member names exactly — CommandLineParser (used by
/// Ryujinx.Headless.SDL2.Options) parses --scaling-filter by name.
public enum ScalingFilter: String, Codable, CaseIterable {
    case bilinear = "Bilinear"
    case fsr = "Fsr"

    var displayName: String {
        switch self {
        case .bilinear: return "Bilinear"
        case .fsr: return "FSR"
        }
    }
}
