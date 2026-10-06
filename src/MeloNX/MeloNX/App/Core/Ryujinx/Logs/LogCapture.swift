//
//  LogCapture.swift
//  MeloNX
//
//  Created by Stossy11 on 22/09/2025.
//


import Foundation

final class LogCapture: ObservableObject {
    static let shared = LogCapture()

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let originalStdout: Int32
    private let originalStderr: Int32

    // Was a single `lazy var` AsyncStream with one continuation - every
    // simultaneous consumer (LogView already mounts more than one
    // instance; BootDiagnostics now also observes [BOOT] lines) raced to
    // "steal" each element from the same continuation, so any given line
    // was only guaranteed to reach ONE of them. Each call to `logs` now
    // hands back its own independent stream fed from the same capture
    // point, so every subscriber sees every line.
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]
    public private(set) var capturedLogs: [String] = []

    var logs: AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    private init() {
        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)
        startCapturing()
    }

    func startCapturing() {
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

        redirectOutput(to: stdoutPipe!, fileDescriptor: STDOUT_FILENO)
        redirectOutput(to: stderrPipe!, fileDescriptor: STDERR_FILENO)

        setupReadabilityHandler(for: stdoutPipe!, isStdout: true)
        setupReadabilityHandler(for: stderrPipe!, isStdout: false)
    }

    func stopCapturing() {
        dup2(originalStdout, STDOUT_FILENO)
        dup2(originalStderr, STDERR_FILENO)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }

    private func redirectOutput(to pipe: Pipe, fileDescriptor: Int32) {
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileDescriptor)
    }

    private func setupReadabilityHandler(for pipe: Pipe, isStdout: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }

            let data = fileHandle.availableData
            let originalFD = isStdout ? self.originalStdout : self.originalStderr
            write(originalFD, (data as NSData).bytes, data.count)

            guard let logString = String(data: data, encoding: .utf8),
                  let cleanedLog = self.cleanLog(logString),
                  !cleanedLog.0.isEmpty else { return }

            self.capturedLogs.append(cleanedLog.1)
            for continuation in self.continuations.values {
                continuation.yield(cleanedLog.0)
            }
        }
    }

    /// Lines that must stay visible even with "Show Full Logs" off - this
    /// fork's own boot/JIT diagnosis prefixes, plus Ryujinx's own
    /// warning/error/exception/HLE lines, which the pre-existing
    /// timestamp-regex filter below was silently dropping whenever they
    /// didn't happen to match that exact "HH:mm:ss.SSS |LEVEL|" shape
    /// (e.g. a raw exception stack trace line has no such prefix at all).
    private static let alwaysVisiblePrefixes = ["[BOOT]", "[JIT]", "[LCJIT]"]
    private static let alwaysVisibleMarkers = ["|Error|", "|Warning|", "|Fatal|", "Unhandled exception", "Exception"]

    private func isAlwaysVisible(_ line: Substring) -> Bool {
        if Self.alwaysVisiblePrefixes.contains(where: { line.hasPrefix($0) }) {
            return true
        }
        return Self.alwaysVisibleMarkers.contains { line.contains($0) }
    }

    private func cleanLog(_ raw: String) -> (String, String)? {
        let lines = raw.split(separator: "\n")

        let filteredLines = lines.filter { line in
            if UserDefaults.standard.bool(forKey: "showFullLogs") {
                return true
            }

            if isAlwaysVisible(line) {
                return true
            }

            let regex = try? NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\|[A-Z]+\\|", options: .caseInsensitive)
            let matches = regex?.matches(in: String(line), options: [], range: NSRange(location: 0, length: line.utf16.count)) ?? []

            return matches.count >= 1
        }

        let cleaned = filteredLines.map { line -> String in
            if let tabRange = line.range(of: "\t") {
                return line[tabRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")
        
        
        let cleaned2 = lines.map { line -> String in
            if let tabRange = line.range(of: "\t") {
                return line[tabRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")

        return cleaned.isEmpty ? nil : (cleaned.replacingOccurrences(of: "\n\n", with: "\n"), cleaned2)
    }

    deinit {
        stopCapturing()
        continuations.values.forEach { $0.finish() }
    }
}
