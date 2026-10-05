//
//  PairingFileImporter.swift
//  MeloNX
//

import Foundation

/// Imports a StikJIT pairing file to the standard location
/// (BuiltInStikJITAvailability.pairingFileURL), per INTEGRATION.md's
/// "Built-in StikJIT: Store and import the pairing file": security-scoped
/// access while copying, atomic replace, never log its contents.
enum PairingFileImporter {
    enum ImportError: LocalizedError {
        case accessDenied
        case copyFailed(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "MeloNX couldn't access the selected file."
            case .copyFailed(let error):
                return "Couldn't import the pairing file: \(error.localizedDescription)"
            }
        }
    }

    /// `source` is expected to be a security-scoped URL from a file
    /// importer/picker — this brackets the whole copy in
    /// start/stopAccessingSecurityScopedResource.
    static func importPairingFile(from source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard accessing else {
            throw ImportError.accessDenied
        }

        let destination = BuiltInStikJITAvailability.pairingFileURL
        let directory = destination.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ImportError.copyFailed(error)
        }
    }

    static func removeImportedPairingFile() throws {
        try FileManager.default.removeItem(at: BuiltInStikJITAvailability.pairingFileURL)
    }
}
