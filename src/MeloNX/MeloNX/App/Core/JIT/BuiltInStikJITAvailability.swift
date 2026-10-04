//
//  BuiltInStikJITAvailability.swift
//  MeloNX
//

import Foundation

/// Host-side preflight for "Built-in StikJIT" — StikJIT.xcframework
/// (MPL-2.0, https://github.com/StikDebug/StikJIT) embedded in a helper
/// app extension, per its INTEGRATION.md "Gate every entry point" and
/// "LiveContainer" sections.
///
/// This is availability-checking only. It does not link StikJIT.xcframework
/// or talk to any helper extension, because neither exists in this project
/// yet: Built-in StikJIT requires a second process (a process can't attach
/// a debugger to itself), i.e. a helper app extension that links the
/// framework and talks to the host over XPC. Adding that extension target
/// is a separate, later step. This file exists so the gating logic — real,
/// host-side, needed regardless of how the helper is eventually wired up —
/// is in place and verified against the real integration contract now,
/// rather than invented later under time pressure.
///
/// INTEGRATION.md lists iOS 17.4+ as a required gate, but MeloNX's own
/// deployment target is already 18.1 — every running instance already
/// satisfies 17.4, so that check is omitted here rather than kept as dead
/// weight.
enum BuiltInStikJITAvailability {
    enum UnavailableReason: Equatable {
        case missingGetTaskAllow
        case runningInLiveContainer
        case noPairingFileImported
    }

    /// `Documents/StikJIT/pairingFile.plist`, the location INTEGRATION.md
    /// documents as the recommended host-app pairing file path. Only the
    /// existence check lives here — importing one (UIDocumentPickerViewController,
    /// atomic replace, Files app access) is pairing-file management, a
    /// separate, later piece of work.
    static var pairingFileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT")
            .appendingPathComponent("pairingFile.plist")
    }

    static var hasImportedPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    /// Mirrors INTEGRATION.md's host-side checks: `get-task-allow` (reuses
    /// the existing `checkAppEntitlement`, not a new SPI call) and a
    /// readable pairing file, plus the separate LiveContainer exclusion
    /// ("Built-in StikJIT is unavailable when the host app is running
    /// inside LiveContainer because LiveContainer cannot create the
    /// required helper extension") — reusing MeloNX's existing
    /// `isInLiveContainer` detection rather than the generic
    /// `getenv("LC_HOME_PATH")` sample from the integration guide.
    static func unavailableReason() -> UnavailableReason? {
        if isInLiveContainer.0 {
            return .runningInLiveContainer
        }

        guard checkAppEntitlement("get-task-allow") else {
            return .missingGetTaskAllow
        }

        guard hasImportedPairingFile else {
            return .noPairingFileImported
        }

        return nil
    }

    static var isAvailable: Bool {
        unavailableReason() == nil
    }
}
