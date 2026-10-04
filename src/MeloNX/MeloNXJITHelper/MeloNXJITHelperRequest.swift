//
//  MeloNXJITHelperRequest.swift
//  MeloNXJITHelper
//

import Foundation

/// The JSON payload carried in an NSExtensionItem.userInfo between the host
/// app and this helper (StikDebug/StikJIT INTEGRATION.md's "Built-in
/// StikJIT: Embed the framework" — the host can't attach a debugger to
/// itself, so a second process does it, and XPC/NSExtensionContext carries
/// the request and result across that boundary).
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
