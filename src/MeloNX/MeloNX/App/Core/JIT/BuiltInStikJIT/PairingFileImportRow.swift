//
//  PairingFileImportRow.swift
//  MeloNX
//

import SwiftUI
import UniformTypeIdentifiers

/// "Import Pairing File" action + status, from INTEGRATION.md's
/// recommended Built-in StikJIT settings list. Self-contained: it doesn't
/// touch JIT method selection (the useTrollStore/stikJIT toggles) — the
/// pairing file it stores is only consumed once Built-in StikJIT itself
/// is wired into LaunchGameHandler, a separate, later step.
struct PairingFileImportRow: View {
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var hasPairingFile = BuiltInStikJITAvailability.hasImportedPairingFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isImporting = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundColor(.blue)
                    Text("Import Pairing File")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(hasPairingFile ? "Imported" : "None")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                do {
                    try PairingFileImporter.importPairingFile(from: url)
                    hasPairingFile = true
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
