//
//  SaveDataInspector.swift
//  MeloNX
//

import Foundation

/// Real visibility into the emulated console's save/user data, kept
/// under Documents/bis — confirmed by reading Ryujinx.removeFirmware(),
/// the only existing code that touches this folder
/// (Documents/bis/system/Contents/registered holds firmware NCAs).
///
/// This inspector — and SaveDataBackupManager — deliberately treat
/// `bis` minus the confirmed `system` (firmware) subfolder as "save/user
/// data," rather than hardcoding a `bis/user` path by name: nothing in
/// this Swift-visible tree names that subfolder, so assuming it would be
/// guessing rather than verifying. Excluding only what's actually
/// confirmed (system = firmware, large and freely re-obtainable) is the
/// defensible boundary — including it in a backup would needlessly
/// bloat something whose actual value is protecting irreplaceable save
/// progress, not firmware.
enum SaveDataInspector {
    struct Info {
        let fileCount: Int
        let totalBytes: Int64
    }

    /// Documents/bis, excluding the confirmed-firmware `system` subfolder.
    static var saveRelevantFolders: [URL] {
        let bisURL = URL.documentsDirectory.appendingPathComponent("bis")
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(at: bisURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        return contents.filter { $0.lastPathComponent != "system" }
    }

    static func currentInfo() -> Info {
        let fileManager = FileManager.default
        var fileCount = 0
        var totalBytes: Int64 = 0

        for folder in saveRelevantFolders {
            guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true else {
                    continue
                }
                fileCount += 1
                totalBytes += Int64(values.fileSize ?? 0)
            }
        }

        return Info(fileCount: fileCount, totalBytes: totalBytes)
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
