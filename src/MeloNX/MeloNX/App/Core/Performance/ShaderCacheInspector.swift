//
//  ShaderCacheInspector.swift
//  MeloNX
//

import Foundation

/// Real visibility into the on-disk shader cache the existing "Shader
/// Cache" setting (Ryujinx.Arguments.enableShaderCache) builds up — the
/// same folder Ryujinx.clearShaderCache() already clears
/// (Documents/games/<titleId>/cache).
///
/// There is no separate "prewarm" entry point to trigger: checked the
/// real RyujinxBridge surface (every exposed function, not a guess) and
/// there is nothing beyond mainRyu() that touches this cache. The only
/// way it's ever populated is by actually launching a game — which
/// already shows progress via the existing ProgressWithPTCorShaderCache
/// callback in LoadingOverlayView. The toggle's own description says it
/// "preloads them on game install," but that's describing the cache
/// warming up over time as the game keeps being played, not a separate
/// install-time step; there's no install-time hook in RyujinxBridge
/// either. This file doesn't invent one — it gives real visibility into
/// the cache that already exists, nothing more.
enum ShaderCacheInspector {
    struct CacheInfo {
        let fileCount: Int
        let totalBytes: Int64
    }

    static func cacheInfo(forTitleId titleId: String) -> CacheInfo {
        info(at: cacheURL(forTitleId: titleId))
    }

    static func totalCacheInfo() -> CacheInfo {
        let gamesURL = URL.documentsDirectory.appendingPathComponent("games")
        let fileManager = FileManager.default

        guard let folders = try? fileManager.contentsOfDirectory(at: gamesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return CacheInfo(fileCount: 0, totalBytes: 0)
        }

        return folders.reduce(CacheInfo(fileCount: 0, totalBytes: 0)) { total, folder in
            let folderInfo = info(at: folder.appendingPathComponent("cache"))
            return CacheInfo(
                fileCount: total.fileCount + folderInfo.fileCount,
                totalBytes: total.totalBytes + folderInfo.totalBytes
            )
        }
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func cacheURL(forTitleId titleId: String) -> URL {
        URL.documentsDirectory
            .appendingPathComponent("games")
            .appendingPathComponent(titleId)
            .appendingPathComponent("cache")
    }

    private static func info(at url: URL) -> CacheInfo {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return CacheInfo(fileCount: 0, totalBytes: 0)
        }

        var fileCount = 0
        var totalBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else {
                continue
            }
            fileCount += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }

        return CacheInfo(fileCount: fileCount, totalBytes: totalBytes)
    }
}
