//
//  MeloNXJITHelperRequest.swift
//  MeloNX
//

import Foundation

/// The JSON payload carried in an NSExtensionItem.userInfo between this
/// host and MeloNXJITHelper.appex. Must stay byte-for-byte identical to
/// MeloNXJITHelper's own copy (src/MeloNX/MeloNXJITHelper/) — duplicated
/// rather than shared across targets: this project's Xcode folders are
/// PBXFileSystemSynchronizedRootGroups, one per target, and sharing this
/// file would mean editing the host's existing (already-working)
/// synchronized-group exceptions for a struct this small, which isn't
/// worth the risk.
struct MeloNXJITHelperRequest: Codable {
    enum Operation: String, Codable {
        case prepare
        case enable
        case resetDDI
    }

    static let itemKey = "com.stossy11.MeloNX.JITHelperRequest"

    struct Response: Codable {
        static let itemKey = "com.stossy11.MeloNX.JITHelperResponse"

        var success: Bool
        var message: String
        var txmPresent: Bool?
    }

    var operation: Operation
    var targetPID: Int32?
    var pairingData: Data?
}
