//
//  JITDiagnostics.swift
//  MeloNX
//

import Foundation
import UIKit

/// On-device JIT diagnosis, visible and copyable without Xcode/Mac. Exists
/// because "JIT Not Acquired" alone tells a user nothing about *which*
/// method was even tried, in what order, or why it failed — this builds
/// the same report a developer would otherwise have to get from a Mac
/// console, straight onto the device.
///
/// Deliberately does not claim `increased-memory-limit` means JIT is
/// available — this fork's own LaunchGameHandler stopped gating on it
/// (shouldLaunchGame/shouldShowPopover/shouldCheckJIT), since a free
/// AltStore signature can't carry it at all; it's reported here purely as
/// one more entitlement value, never as a readiness signal.
enum JITDiagnostics {
    static func buildReport() -> String {
        var lines: [String] = ["[JIT DIAGNOSTICS]", ""]

        lines.append("App:")
        lines.append(contentsOf: appLines())
        lines.append("")

        lines.append("Entitlements:")
        lines.append(contentsOf: entitlementLines())
        lines.append("")

        lines.append("Settings:")
        lines.append(contentsOf: settingsLines())
        lines.append("")

        lines.append("Runtime:")
        lines.append(contentsOf: runtimeLines())
        lines.append("")

        lines.append("Coordinator:")
        lines.append(contentsOf: coordinatorLines())
        lines.append("")

        for (index, attempt) in JITCoordinator.shared.methodAttempts.enumerated() {
            lines.append("METHOD \(index + 1):")
            lines.append("name = \(attempt.name)")
            lines.append("started = \(attempt.startedAt)")
            lines.append("result = \(attempt.result)")
            lines.append("error = \(attempt.error ?? "none")")
            lines.append("elapsed = \(attempt.elapsed.map { String(format: "%.2fs", $0) } ?? "-")")
            lines.append("")
        }

        lines.append("FINAL:")
        lines.append("acquired = \(JITCoordinator.shared.state == .ready)")
        lines.append("failureReason = \(JITCoordinator.shared.lastFailureReason ?? "none")")

        return lines.joined(separator: "\n")
    }

    private static func appLines() -> [String] {
        [
            "bundleIdentifier = \(Bundle.main.bundleIdentifier ?? "unknown")",
            "iOS = \(UIDevice.current.systemVersion)",
            "device = \(UIDevice.current.model)",
            // Not a parsed provisioning profile — the closest runtime signal
            // this app already has for "how was this installed":
            // get-task-allow/dynamic-codesigning distinguish a free AltStore
            // signature from TrollStore/jailbroken installs, and
            // isInLiveContainer catches the sideloaded-inside-LiveContainer case.
            "installationMethod/known signing info = get-task-allow=\(checkAppEntitlement("get-task-allow")), dynamic-codesigning=\(checkAppEntitlement("dynamic-codesigning")), isInLiveContainer=\(isInLiveContainer.0), isiOSAppOnMac=\(ProcessInfo.processInfo.isiOSAppOnMac)",
        ]
    }

    private static func entitlementLines() -> [String] {
        [
            "get-task-allow = \(checkAppEntitlement("get-task-allow"))",
            "dynamic-codesigning = \(checkAppEntitlement("dynamic-codesigning"))",
            "increased-memory-limit = \(checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit"))",
            "extended-virtual-addressing = \(checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing"))",
        ]
    }

    private static func settingsLines() -> [String] {
        let s = NativeSettingsManager.shared
        return [
            "builtInStikJIT = \(s.builtInStikJIT.value)",
            "externalStikJIT = \(s.stikJIT.value)",
            "useTrollStore = \(s.useTrollStore.value)",
            "ignoreJIT = \(s.ignoreJIT.value)",
        ]
    }

    private static func runtimeLines() -> [String] {
        let executableMemory = allocateTest()
        let changeProtection = canChangeMemoryProtection()
        let mapJit = mapJitTest()
        let jitWriteProtect = pthreadJitWriteProtectAvailable()
        let debugged = checkDebugged()
        let alreadyAvailable = isJITEnabled()

        JITCoordinator.shared.logDiag("[JIT] executable memory test result = \(executableMemory)")

        return [
            "jitAlreadyAvailable = \(alreadyAvailable)",
            "canAllocateExecutableMemory = \(executableMemory)",
            "canChangeMemoryProtection = \(changeProtection)",
            "MAP_JIT test = \(mapJit)",
            "pthread_jit_write_protect available = \(jitWriteProtect)",
            "debuggerAttached = \(debugged)",
        ]
    }

    private static func coordinatorLines() -> [String] {
        let state = JITCoordinator.shared.state
        let attemptText: String
        if case .waiting(let attempt) = state {
            attemptText = "\(attempt)"
        } else {
            attemptText = "-"
        }

        return [
            "state = \(state)",
            "attempt = \(attemptText)",
            "enabledMethods = \(enabledMethodNames().joined(separator: ", "))",
        ]
    }

    /// JITStreamerEB is always attempted first regardless of any toggle
    /// (LaunchGameHandler.enableJIT()) — listed unconditionally for that
    /// reason, not because a setting enables it.
    static func enabledMethodNames() -> [String] {
        let s = NativeSettingsManager.shared
        var names = ["JITStreamerEB (internal, always attempted first)"]
        if s.useTrollStore.value { names.append("TrollStore") }
        if s.stikJIT.value { names.append("StikDebug (external app)") }
        if BuiltInStikJITAvailability.isAvailable { names.append("Built-in StikJIT") }
        if names.count == 1 {
            names.append("(none enabled besides the internal path)")
        }
        return names
    }

    static func copyReportToClipboard() {
        UIPasteboard.general.string = buildReport()
        JITCoordinator.shared.logDiag("[JIT] diagnostics copied to clipboard")
    }

    // MARK: - Runtime capability probes

    /// Distinct from allocateTest(): this only checks whether mprotect()
    /// itself succeeds going RW -> RX, without also verifying the mapping
    /// is truly executable afterward — separates "the syscall was allowed"
    /// from "the memory can really run code".
    private static func canChangeMemoryProtection() -> Bool {
        let pageSize = sysconf(_SC_PAGESIZE)
        guard let memory = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), memory != MAP_FAILED else {
            return false
        }
        defer { munmap(memory, pageSize) }

        let succeeded = mprotect(memory, pageSize, PROT_READ | PROT_EXEC) == 0
        _ = mprotect(memory, pageSize, PROT_READ | PROT_WRITE)
        return succeeded
    }

    /// MAP_JIT (0x0800 on Darwin) is a distinct OS-level gate from the plain
    /// mmap+mprotect dance allocateTest()/canChangeMemoryProtection() use —
    /// hardcoded rather than imported since iOS SDK headers don't
    /// consistently expose the MAP_JIT constant the way macOS's do.
    private static func mapJitTest() -> Bool {
        let mapJitFlag: Int32 = 0x0800
        let pageSize = sysconf(_SC_PAGESIZE)
        guard let memory = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | mapJitFlag, -1, 0), memory != MAP_FAILED else {
            return false
        }
        munmap(memory, pageSize)
        return true
    }

    private static func pthreadJitWriteProtectAvailable() -> Bool {
        dlsym(dlopen(nil, RTLD_NOW), "pthread_jit_write_protect_np") != nil
    }
}
