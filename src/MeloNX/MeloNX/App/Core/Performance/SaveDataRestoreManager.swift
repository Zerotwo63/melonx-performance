//
//  SaveDataRestoreManager.swift
//  MeloNX
//

import Foundation

/// Restores a previous SaveDataBackupManager export back into the live
/// Documents/bis — the destructive half of the save/backup manager,
/// deliberately built as its own, separate, later step (see
/// SaveDataBackupManager's doc comment history).
///
/// Before overwriting anything, this always creates its own safety
/// snapshot of the CURRENT live data first, via
/// SaveDataBackupManager.createPreRestoreSnapshot() — no folder picker
/// needed for that, since it never leaves the app's own sandbox. If a
/// restore turns out to be the wrong call, that snapshot is the
/// fallback.
enum SaveDataRestoreManager {
    enum RestoreError: LocalizedError {
        case accessDenied
        case notARecognizedBackup
        case restoreFailed(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "MeloNX couldn't access the selected folder."
            case .notARecognizedBackup:
                return "This doesn't look like a MeloNX save backup folder."
            case .restoreFailed(let error):
                return "Couldn't finish the restore: \(error.localizedDescription)"
            }
        }
    }

    /// The exact prefix SaveDataBackupManager.exportBackup(to:) names
    /// every backup folder with — used as a simple, concrete sanity
    /// check against restoring from an unrelated, wrongly-picked folder.
    /// Not foolproof (a folder could be renamed to match), but a real
    /// guard against the realistic failure mode of picking the wrong
    /// folder by mistake.
    static let backupFolderPrefix = "MeloNX-SaveBackup-"

    /// `backupFolder` is expected to be a security-scoped folder URL
    /// from a folder picker/importer, pointing at a folder previously
    /// created by SaveDataBackupManager.exportBackup(to:). Returns the
    /// safety snapshot folder created before the restore.
    @discardableResult
    static func restoreBackup(from backupFolder: URL) throws -> URL {
        guard backupFolder.lastPathComponent.hasPrefix(backupFolderPrefix) else {
            throw RestoreError.notARecognizedBackup
        }

        let accessing = backupFolder.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                backupFolder.stopAccessingSecurityScopedResource()
            }
        }

        guard accessing else {
            throw RestoreError.accessDenied
        }

        let safetySnapshot: URL
        do {
            safetySnapshot = try SaveDataBackupManager.createPreRestoreSnapshot()
        } catch {
            throw RestoreError.restoreFailed(error)
        }

        let fileManager = FileManager.default
        let bisURL = URL.documentsDirectory.appendingPathComponent("bis")

        do {
            let subfolders = try fileManager.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

            for subfolder in subfolders where subfolder.lastPathComponent != "system" {
                let liveDestination = bisURL.appendingPathComponent(subfolder.lastPathComponent)
                try SaveDataBackupManager.overwriteContents(of: subfolder, into: liveDestination, fileManager: fileManager)
            }
        } catch {
            throw RestoreError.restoreFailed(error)
        }

        return safetySnapshot
    }
}
