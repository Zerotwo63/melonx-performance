//
//  SaveDataBackupCard.swift
//  MeloNX
//

import SwiftUI
import UniformTypeIdentifiers

/// Real save-data backup: shows the actual size of the console's
/// save/user data (SaveDataInspector), a working "Back Up Save Data"
/// action that copies it to a folder the user picks
/// (SaveDataBackupManager), and "Restore from Backup"
/// (SaveDataRestoreManager) — gated behind an explicit confirmation
/// since it overwrites live save data, matching the same
/// confirm-before-destroying pattern Ryujinx.clearShaderCache() already
/// uses elsewhere in this app.
struct SaveDataBackupCard: View {
    @State private var info: SaveDataInspector.Info?
    @State private var isPickingBackupFolder = false
    @State private var isPickingRestoreFolder = false
    @State private var pendingRestoreFolder: URL?
    @State private var showRestoreConfirmation = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .foregroundColor(.blue)
                    Text("Save Data Backup")
                        .font(.headline)
                    Spacer()
                }

                if let info {
                    Text(info.fileCount == 0
                        ? "No save data found yet."
                        : "\(SaveDataInspector.formattedSize(info.totalBytes)) across \(info.fileCount) files.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Button {
                    isPickingBackupFolder = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Back Up Save Data")
                        Spacer()
                    }
                }

                Button(role: .destructive) {
                    isPickingRestoreFolder = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Restore from Backup")
                        Spacer()
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsError ? .red : .green)
                }
            }
            .padding(.vertical, 4)
        }
        .fileImporter(isPresented: $isPickingBackupFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    let backupFolder = try SaveDataBackupManager.exportBackup(to: url)
                    statusMessage = "Backed up to \(backupFolder.lastPathComponent)."
                    statusIsError = false
                    refresh()
                } catch {
                    statusMessage = error.localizedDescription
                    statusIsError = true
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
        .fileImporter(isPresented: $isPickingRestoreFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                pendingRestoreFolder = url
                showRestoreConfirmation = true
            case .failure(let error):
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
        .alert("Restore Save Data?", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingRestoreFolder = nil
            }
            Button("Restore", role: .destructive) {
                performRestore()
            }
        } message: {
            Text("This overwrites your current save data with the contents of \(pendingRestoreFolder?.lastPathComponent ?? "this backup"). A safety copy of your current data is made first, just in case.")
        }
        .onAppear {
            refresh()
        }
    }

    private func performRestore() {
        guard let folder = pendingRestoreFolder else { return }
        pendingRestoreFolder = nil

        do {
            let snapshot = try SaveDataRestoreManager.restoreBackup(from: folder)
            statusMessage = "Restored. Previous data saved to \(snapshot.lastPathComponent)."
            statusIsError = false
            refresh()
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let result = SaveDataInspector.currentInfo()
            DispatchQueue.main.async {
                info = result
            }
        }
    }
}
