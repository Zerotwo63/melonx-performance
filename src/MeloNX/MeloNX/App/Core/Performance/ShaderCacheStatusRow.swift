//
//  ShaderCacheStatusRow.swift
//  MeloNX
//

import SwiftUI

/// Shows the real on-disk size of this game's shader cache, next to the
/// existing "Shader Cache" toggle in PerGameSettingsView — the toggle
/// alone gives no indication of whether the cache has ever actually
/// built up anything. Purely informational: clearing the cache already
/// has its own entry points (GamesListView's per-game action, Settings'
/// "Clear All Shader Cache") whose deletion happens asynchronously
/// behind a confirmation alert with no completion callback — there's no
/// reliable way to know from here when it's actually finished to
/// refresh afterward, so this doesn't try to add a second "Clear"
/// button of its own.
struct ShaderCacheStatusRow: View {
    let titleId: String

    @State private var info: ShaderCacheInspector.CacheInfo?

    var body: some View {
        HStack {
            Text("Cache size")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if let info {
                Text(info.fileCount == 0 ? "Empty" : ShaderCacheInspector.formattedSize(info.totalBytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let result = ShaderCacheInspector.cacheInfo(forTitleId: titleId)
            DispatchQueue.main.async {
                info = result
            }
        }
    }
}
