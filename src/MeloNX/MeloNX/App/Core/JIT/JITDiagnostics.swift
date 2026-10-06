//
//  JITDiagnostics.swift
//  MeloNX
//

import Foundation
import Darwin
import UIKit

/// On-device JIT diagnosis, visible and verifiable without Xcode/Mac. A
/// SwiftUI .alert's buttons dismiss the alert the instant any of them is
/// tapped, with nowhere for the user to actually read the result — this
/// exists so JITDiagnosticsView has a real report to show, independent of
/// the clipboard ever working.
///
/// Deliberately does not claim `increased-memory-limit` means JIT is
/// available — this fork's LaunchGameHandler stopped gating on it
/// (shouldLaunchGame/shouldShowPopover/shouldCheckJIT), since a free
/// AltStore signature can't carry it at all; it's reported here purely as
/// one more entitlement value, never as a readiness signal.
enum JITDiagnostics {
    /// One real measurement of whether this process can actually run
    /// freshly-written code right now - never inferred from a method
    /// claiming success. mmap/mprotect/munmap only; cannot crash.
    struct ExecMemoryProbeResult {
        let mmapSucceeded: Bool
        let mprotectSucceeded: Bool
        let errnoValue: Int32
        let errorDescription: String
        var overallSuccess: Bool { mmapSucceeded && mprotectSucceeded }
    }

    struct MethodCapability {
        let method: String
        let available: Bool
        let enabled: Bool
        let reasonUnavailable: String?
    }

    static func probeExecutableMemory() -> ExecMemoryProbeResult {
        let pageSize = sysconf(_SC_PAGESIZE)

        guard let memory = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), memory != MAP_FAILED else {
            let code = errno
            return ExecMemoryProbeResult(mmapSucceeded: false, mprotectSucceeded: false, errnoValue: code, errorDescription: String(cString: strerror(code)))
        }
        defer { munmap(memory, pageSize) }

        // mov w0, #42 ; ret - minimal, safe, never actually jumped to; only
        // mprotect()'s own return value is being measured here.
        let code: [UInt32] = [0x52800540, 0xD65F03C0]
        memcpy(memory, code, code.count * MemoryLayout<UInt32>.size)

        let mprotectResult = mprotect(memory, pageSize, PROT_READ | PROT_EXEC)
        let mprotectSucceeded = mprotectResult == 0
        let mprotectErrno = errno
        _ = mprotect(memory, pageSize, PROT_READ | PROT_WRITE) // best-effort restore before munmap

        return ExecMemoryProbeResult(
            mmapSucceeded: true,
            mprotectSucceeded: mprotectSucceeded,
            errnoValue: mprotectSucceeded ? 0 : mprotectErrno,
            errorDescription: mprotectSucceeded ? "" : String(cString: strerror(mprotectErrno))
        )
    }

    /// A always-computed survey of all 4 known methods' current
    /// availability/enablement - independent of whether enableJIT() has
    /// run yet this session. Distinct from JITCoordinator.methodAttempts,
    /// which only has entries for methods actually attempted.
    static func methodCapabilities() -> [MethodCapability] {
        let s = NativeSettingsManager.shared
        var list: [MethodCapability] = []

        list.append(MethodCapability(method: "JITStreamerEB (internal)", available: true, enabled: true, reasonUnavailable: nil))

        list.append(MethodCapability(
            method: "TrollStore",
            available: true,
            enabled: s.useTrollStore.value,
            reasonUnavailable: s.useTrollStore.value ? nil : "toggle disabled in Settings"
        ))

        let stikDetected = detectStikTool() != .notFound
        list.append(MethodCapability(
            method: "StikJIT/StikDebug (external app)",
            available: stikDetected,
            enabled: s.stikJIT.value,
            reasonUnavailable: !stikDetected
                ? "no StikDebug/StikJIT app installed (no URL scheme handler found)"
                : (s.stikJIT.value ? nil : "toggle disabled in Settings")
        ))

        list.append(MethodCapability(
            method: "Built-in StikJIT",
            available: BuiltInStikJITAvailability.isAvailable,
            enabled: s.builtInStikJIT.value,
            reasonUnavailable: BuiltInStikJITAvailability.unavailableReason().map(reasonText(for:))
        ))

        return list
    }

    static func reasonText(for reason: BuiltInStikJITAvailability.UnavailableReason) -> String {
        switch reason {
        case .missingGetTaskAllow:
            return "this signature does not include get-task-allow"
        case .runningInLiveContainer:
            return "MeloNX is running inside LiveContainer"
        case .noPairingFileImported:
            return "no pairing file has been imported for the built-in JIT helper"
        case .helperMissing:
            return "the MeloNX JIT helper extension is missing from this installation"
        }
    }

    /// JITStreamerEB is always attempted first regardless of any toggle.
    static func enabledMethodNames() -> [String] {
        let s = NativeSettingsManager.shared
        var names = ["JITStreamerEB (internal, always attempted first)"]
        if s.useTrollStore.value { names.append("TrollStore") }
        if s.stikJIT.value { names.append("StikDebug/StikJIT (external app)") }
        if BuiltInStikJITAvailability.isAvailable { names.append("Built-in StikJIT") }
        if names.count == 1 {
            names.append("(none enabled besides the internal path)")
        }
        return names
    }

    static func buildReport() -> String {
        var lines: [String] = ["[JIT DIAGNOSTICS]", ""]
        lines.append("timestamp = \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("IOS:")
        lines.append("version = \(UIDevice.current.systemVersion)")
        lines.append("device = \(UIDevice.current.model)")
        lines.append("processPID = \(getpid())")
        lines.append("")

        lines.append("ENTITLEMENTS:")
        let increasedMemoryLimit = checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit")
        lines.append("get-task-allow = \(checkAppEntitlement("get-task-allow"))")
        lines.append("dynamic-codesigning = \(checkAppEntitlement("dynamic-codesigning"))")
        lines.append("increased-memory-limit = \(increasedMemoryLimit)")
        lines.append("extended-virtual-addressing = \(checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing"))")
        lines.append("hasJITEntitlement (legacy LaunchGameHandler name for increased-memory-limit; does NOT gate anything anymore) = \(increasedMemoryLimit)")
        lines.append("")

        lines.append("CURRENT PROCESS:")
        let probe = probeExecutableMemory()
        lines.append("jitAlreadyAvailable = \(isJITEnabled())")
        lines.append("executableMemoryTest = \(probe.overallSuccess)")
        lines.append("mmapRW = \(probe.mmapSucceeded)")
        lines.append("mprotectRX = \(probe.mprotectSucceeded)")
        lines.append("result = \(probe.overallSuccess ? "pass" : "fail")")
        lines.append("errno = \(probe.errnoValue)")
        lines.append("errorDescription = \(probe.errorDescription.isEmpty ? "none" : probe.errorDescription)")
        lines.append("")

        lines.append("SETTINGS:")
        let s = NativeSettingsManager.shared
        lines.append("stikJIT = \(s.stikJIT.value)")
        lines.append("builtInStikJIT = \(s.builtInStikJIT.value)")
        lines.append("useTrollStore = \(s.useTrollStore.value)")
        lines.append("ignoreJIT = \(s.ignoreJIT.value)")
        lines.append("")

        lines.append("METHOD DETECTION:")
        for capability in methodCapabilities() {
            lines.append("method = \(capability.method)")
            lines.append("available = \(capability.available)")
            lines.append("enabled = \(capability.enabled)")
            lines.append("reasonUnavailable = \(capability.reasonUnavailable ?? "none")")
            lines.append("")
        }

        lines.append("ATTEMPT ORDER:")
        lines.append("1. JITStreamerEB (internal, always attempted first)")
        lines.append("2. TrollStore (only if its Settings toggle is on)")
        lines.append("3. StikDebug/StikJIT external app (only if its Settings toggle is on)")
        lines.append("4. Built-in StikJIT (only if available, and nothing above succeeded)")
        lines.append("")

        for attempt in JITCoordinator.shared.methodAttempts {
            lines.append("[JIT METHOD]")
            lines.append("name = \(attempt.name)")
            lines.append("detected = \(attempt.detected)")
            lines.append("enabled = \(attempt.enabled)")
            lines.append("attempted = \(attempt.attempted)")
            lines.append("startTime = \(attempt.startedAt)")
            lines.append("endTime = \(attempt.endedAt.map { "\($0)" } ?? "-")")
            lines.append("duration = \(attempt.elapsed.map { String(format: "%.2fs", $0) } ?? "-")")
            lines.append("result = \(attempt.result)")
            lines.append("error = \(attempt.error ?? "none")")
            lines.append("underlyingError = \(attempt.underlyingError ?? "none")")
            lines.append("errno = \(attempt.errnoValue.map { "\($0)" } ?? "-")")
            lines.append("timeout = \(attempt.timedOut)")
            lines.append("pairingStatus = \(attempt.pairingStatus ?? "n/a")")
            lines.append("connectionStatus = \(attempt.connectionStatus ?? "n/a")")
            lines.append("")
        }

        lines.append("COORDINATOR:")
        let state = JITCoordinator.shared.state
        lines.append("state = \(state)")
        if case .waiting(let attempt) = state {
            lines.append("attempt = \(attempt)")
        } else {
            lines.append("attempt = -")
        }
        lines.append("retryCount = \(JITCoordinator.shared.retryCount)")
        lines.append("")

        lines.append("FINAL:")
        lines.append("acquired = \(state == .ready)")
        lines.append("failureReason = \(JITCoordinator.shared.lastFailureReason ?? "none")")
        lines.append("")

        lines.append("LOG:")
        lines.append(contentsOf: JITCoordinator.shared.diagnosticsLog)

        return lines.joined(separator: "\n")
    }

    /// Builds the report AND writes it to Documents/jit-diagnostics.txt so
    /// the data survives even if the clipboard/pasteboard path fails for
    /// any reason - the explicit "don't lose the data" requirement.
    @discardableResult
    static func generateAndPersistReport() -> String {
        let report = buildReport()
        let url = URL.documentsDirectory.appendingPathComponent("jit-diagnostics.txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            JITCoordinator.shared.logDiag("[JIT] failed to save diagnostics to disk: \(error.localizedDescription)")
        }
        return report
    }
}
