//
//  BuiltInStikJITAvailability.swift
//  MeloNX
//

import Foundation

/// Host-side preflight for "Built-in StikJIT" — StikJIT.xcframework
/// (MPL-2.0, https://github.com/StikDebug/StikJIT) embedded in the
/// MeloNXJITHelper app extension (App/Core/JIT/BuiltInStikJIT/), per
/// INTEGRATION.md's "Gate every entry point" and "LiveContainer" sections.
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
        case helperMissing
    }

    /// `MeloNXJITHelper.appex`'s bundle identifier in *this* installation,
    /// read from its own Info.plist rather than assumed — a sideloader
    /// that re-signs with the user's own Apple ID renames the host's
    /// bundle ID (and the helper's along with it, since it's nested under
    /// the host's), but can also strip app extensions entirely depending
    /// on the tool, so this can legitimately be nil.
    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MeloNXJITHelper.appex") else {
            return nil
        }
        return Bundle(url: url)?.bundleIdentifier
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

        guard helperIdentifier != nil else {
            return .helperMissing
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
