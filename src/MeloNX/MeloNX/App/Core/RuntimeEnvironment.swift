//
//  RuntimeEnvironment.swift
//  MeloNX
//

import Foundation

/// Centralizes "is this process running inside LiveContainer" — previously
/// checked ad hoc via the `isInLiveContainer` global in a handful of
/// places. Does NOT reimplement detection: `isInLiveContainer` is already
/// set once, correctly, in `Bundle.swizzleBundleIdentifier()`
/// (FilePickerfix.swift), by asking LiveContainer's own injected
/// `NSUserDefaults.lcMainBundle`/`isLiveProcess` (see `liveContainer()`
/// there) — not `getenv("LC_HOME_PATH")`, which this project never used.
enum RuntimeEnvironment {
    static var isLiveContainer: Bool {
        isInLiveContainer.0
    }

    static var label: String {
        isLiveContainer ? "LiveContainer" : "native"
    }

    /// Call once at the point boot actually needs to branch on this -
    /// logs through BootDiagnostics so it lands in both the console and
    /// the persisted boot report.
    static func logDetection() {
        BootDiagnostics.shared.log("environment", result: label)
    }
}
