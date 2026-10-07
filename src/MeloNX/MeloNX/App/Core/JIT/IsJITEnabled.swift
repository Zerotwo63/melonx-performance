//
//  IsJITEnabled.swift
//  MeloNX
//
//  Created by Stossy11 on 10/02/2025.
//

import Foundation

@_silgen_name("csops")
func csops(pid: Int32, ops: Int32, useraddr: UnsafeMutableRawPointer?, usersize: Int32) -> Int32

func isJITEnabled() -> Bool {

    if checkAppEntitlement("dynamic-codesigning") {
        return allocateTest()
    }
    
    LaunchGameHandler.succeededJIT = RyujinxBridge.initialize_dualmapped()
    
    if #available(iOS 19, *) {
        return checkDebugged() && LaunchGameHandler.succeededJIT
    } else {
        return checkDebugged() && allocateTest()
    }
}

func checkDebugged() -> Bool {
    var flags: Int = 0
    if checkAppEntitlement("dynamic-codesigning") {
        return true
    }
    return csops(pid: getpid(), ops: 0, useraddr: &flags, usersize: Int32(MemoryLayout.size(ofValue: flags))) == 0 && (flags & Int(CS_DEBUGGED)) != 0
}

func checkMemoryPermissions(at address: UnsafeRawPointer) -> Bool {
    var region: vm_address_t = vm_address_t(UInt(bitPattern: address))
    var regionSize: vm_size_t = 0
    var info = vm_region_basic_info_64()
    var infoCount = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_64>.size / MemoryLayout<integer_t>.size)
    var objectName: mach_port_t = UInt32(MACH_PORT_NULL)
    
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
            vm_region_64(mach_task_self_, &region, &regionSize, VM_REGION_BASIC_INFO_64, $0, &infoCount, &objectName)
        }
    }
    
    if result != KERN_SUCCESS {
        // print("Failed to reach \(address)")
        return false
    }
    
    return info.protection & VM_PROT_EXECUTE != 0
}
func allocateTest() -> Bool {
    let pageSize = sysconf(_SC_PAGESIZE)
    let code: [UInt32] = [0x52800540, 0xD65F03C0]
    
    guard let jitMemory = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), jitMemory != MAP_FAILED else {
        return false
    }
    
    defer {
        munmap(jitMemory, pageSize)
    }
    
    
    memcpy(jitMemory, code, code.count)
    
    _ = mprotect(jitMemory, pageSize, PROT_READ | PROT_EXEC)
    
    let checkMem = checkMemoryPermissions(at: jitMemory)
    
    return checkMem
}

// thank you nikki (nythepegasus)
extension FileManager {
    func filePath(atPath path: String, withLength length: Int) -> String? {
        guard let file = try? contentsOfDirectory(atPath: path).filter({ $0.count == length }).first else { return nil }
        return "\(path)/\(file)"
    }
}

func notnil(_ condition: Any?) -> Bool {
    if let _ = condition {
        return false
    } else {
        return true
    }
}

/// Tri-state TXM/SPTM presence - `.unknown` MUST NOT be treated the same as
/// `.notPresent` by any caller. The only direct evidence this process can
/// gather is the img4 firmware file's presence (`.present` when found), but
/// its absence does NOT prove TXM is inactive - the exact Preboot path
/// layout and firmware filename are not officially documented and could
/// differ across iOS 26/27 builds or device generations, so a missed file
/// lookup is evidence of nothing. Per this round's real diagnostic
/// (mprotect(PROT_READ|PROT_EXEC) reporting success on an Apple A19 Pro /
/// iOS 26+ device while mach_vm_region shows the page is NOT actually
/// executable afterward - NON_EXECUTABLE_MAPPING), treating an inconclusive
/// file check as proof of absence is exactly the bug that made
/// DualMappedJitAllocator skip the JIT26/BreakGetJITMapping protocol
/// entirely and fall through to a plain mmap/mprotect that iOS silently
/// strips EXECUTE from.
public enum TXMStatus: String {
    case present
    case notPresent
    case unknown
}

public extension ProcessInfo {
    /// `.present` when the img4 file check succeeds (direct evidence).
    /// `.notPresent` only when running an iOS version that predates the
    /// documented iOS 26 TXM/SPTM introduction - a confident negative.
    /// `.unknown` when running iOS 26+ but the file check could not find
    /// the expected file - TXM/SPTM may still be enforced; never treat
    /// this as `.notPresent`.
    var txmStatus: TXMStatus {
        let fileCheckPresent: Bool = {
            if let boot = FileManager.default.filePath(atPath: "/System/Volumes/Preboot", withLength: 36), let file = FileManager.default.filePath(atPath: "\(boot)/boot", withLength: 96) {
                return access("\(file)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0
            } else {
                return (FileManager.default.filePath(atPath: "/private/preboot", withLength: 96).map { access("\($0)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 }) ?? false
            }
        }()

        if fileCheckPresent {
            return .present
        }

        if #available(iOS 26.0, *) {
            return .unknown
        }

        return .notPresent
    }

    /// Compatibility shim for every existing `if hasTXM` call site
    /// (DualMappedJitAllocator's protocol gate, StikEnableJIT's script
    /// attachment decision, LaunchGameHandler's LiveContainer check) -
    /// `.unknown` collapses to `true` so the SAFE, JIT26-protocol-compatible
    /// path is the default on iOS 26+ whenever presence cannot be
    /// disproven, per this round's explicit requirement.
    var hasTXM: Bool {
        txmStatus != .notPresent
    }
}

