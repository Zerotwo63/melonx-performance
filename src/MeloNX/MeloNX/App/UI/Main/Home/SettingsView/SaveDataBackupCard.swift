//
//  SaveDataBackupCard.swift
//  MeloNX
//

import SwiftUI
import UniformTypeIdentifiers

/// Real save-data backup: shows the actual size of the console's
/// save/user data (SaveDataInspector) and a working "Back Up Save Data"
/// action that copies it to a folder the user picks (SaveDataBackupManager).
/// No restore here yet — see SaveDataBackupManager's own doc comment for
/// why that's a deliberately separate, later step.
struct SaveDataBackupCard: View {
    @State private var info: SaveDataInspector.Info?
    @State private var isPickingFolder = false
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
                    isPickingFolder = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Back Up Save Data")
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
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    let backupFolder = try SaveDataBackupManager.exportBackup(to: url)
                    statusMessage = "Backed up to \(backupFolder.lastPathComponent)."
                    statusIsError = false
                } catch {
                    statusMessage = error.localizedDescription
                    statusIsError = true
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
        .onAppear {
            refresh()
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
