//
//  SaveDataBackupManager.swift
//  MeloNX
//

import Foundation

/// Exports (copies) save/user data to a folder the user picks via the
/// Files app, using SaveDataInspector's confirmed scope (Documents/bis
/// minus the firmware `system` subfolder).
///
/// No zip/archive format is used — Foundation has no built-in zip
/// container writer on iOS, and hand-rolling one is real, unverified
/// engineering this fork isn't taking on for a first version. Each file
/// is copied as-is into a dated subfolder at the destination, preserving
/// its relative path.
///
/// Restore lives in SaveDataRestoreManager.swift, its own, separate,
/// later step — see that file. It calls back into
/// createPreRestoreSnapshot() and overwriteContents(of:into:) below to
/// reuse this file's copy primitives rather than duplicating them.
enum SaveDataBackupManager {
    enum BackupError: LocalizedError {
        case accessDenied
        case copyFailed(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "MeloNX couldn't access the selected folder."
            case .copyFailed(let error):
                return "Couldn't finish the backup: \(error.localizedDescription)"
            }
        }
    }

    /// `destination` is expected to be a security-scoped folder URL from
    /// a folder picker/importer. Returns the backup folder actually
    /// created at the destination.
    @discardableResult
    static func exportBackup(to destination: URL) throws -> URL {
        let accessing = destination.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        guard accessing else {
            throw BackupError.accessDenied
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let backupFolder = destination.appendingPathComponent("MeloNX-SaveBackup-\(dateFormatter.string(from: Date()))")

        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)

            for folder in SaveDataInspector.saveRelevantFolders {
                let folderDestination = backupFolder.appendingPathComponent(folder.lastPathComponent)
                try copyContents(of: folder, to: folderDestination, fileManager: fileManager)
            }
        } catch {
            throw BackupError.copyFailed(error)
        }

        return backupFolder
    }

    private static func copyContents(of source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: source.path, with: "")
            let targetURL = destination.appendingPathComponent(relativePath)

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: fileURL, to: targetURL)
            }
        }
    }

    /// A safety snapshot of the CURRENT live save data, taken
    /// automatically before SaveDataRestoreManager overwrites anything.
    /// Stays entirely inside the app's own sandbox (Documents/SaveBackups),
    /// so — unlike exportBackup(to:) — it needs no folder picker and no
    /// security-scoped access.
    @discardableResult
    static func createPreRestoreSnapshot() throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let snapshotFolder = URL.documentsDirectory
            .appendingPathComponent("SaveBackups")
            .appendingPathComponent("pre-restore-\(dateFormatter.string(from: Date()))")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)

        for folder in SaveDataInspector.saveRelevantFolders {
            let folderDestination = snapshotFolder.appendingPathComponent(folder.lastPathComponent)
            try copyContents(of: folder, to: folderDestination, fileManager: fileManager)
        }

        return snapshotFolder
    }

    /// Copies `source`'s contents into `destination`, replacing any
    /// file that already exists there — unlike copyContents(of:to:)
    /// above, which assumes a fresh, empty destination (true for every
    /// export/snapshot folder, since each is freshly timestamped) and
    /// would simply fail if a target file already existed. Restoring
    /// into the live bis folder is exactly the case where the
    /// destination already has files that need overwriting.
    static func overwriteContents(of source: URL, into destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: source.path, with: "")
            let targetURL = destination.appendingPathComponent(relativePath)

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: fileURL, to: targetURL)
            }
        }
    }
}
