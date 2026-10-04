//
//  MeloNXJITHelperHandler.swift
//  MeloNXJITHelper
//

import Foundation
import StikJIT

/// MeloNX's Built-in StikJIT helper. A second process is required because a
/// process can't attach a debugger to itself (StikDebug/StikJIT
/// INTEGRATION.md, "Built-in StikJIT: Embed the framework"). One
/// MeloNXJITHelperRequest per extension request, answered when the request
/// completes — `enable` only returns once the script has detached, so this
/// process lives as long as the debug connection does.
///
/// Not wired to anything in the host app yet: LaunchGameHandler/
/// BuiltInStikJITAvailability don't launch this extension. That host-side
/// launcher (finding this .appex by bundle ID, starting an NSExtension
/// request, needs a real pairing file to test against) is a separate,
/// later step — this commit is the extension itself: it compiles, links
/// the real StikJIT.xcframework, and is embedded into the IPA.
private enum MeloNXJITWork {
    /// One request at a time — StikJIT's own preparation/enablement calls
    /// are synchronous and blocking and must run on a single dedicated
    /// queue, never concurrently (INTEGRATION.md, "Call the APIs at the
    /// right time").
    static let queue = DispatchQueue(label: "com.stossy11.MeloNX.jit-helper")

    static func handle(_ request: MeloNXJITHelperRequest) -> MeloNXJITHelperRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)

            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "Developer Disk Image cache reset.", txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "MeloNXJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL,
                    paths: paths,
                    progress: { stage in NSLog("[MeloNXJIT] prepare: %@", String(describing: stage)) }
                )
                switch readiness {
                case .ready(let security):
                    return .init(success: true, message: "Ready.", txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown preparation state.", txmPresent: StikJIT.isTXMPresent)
                }

            case .enable:
                guard let targetPID = request.targetPID else {
                    throw NSError(domain: "MeloNXJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The target process was not provided."])
                }
                // MeloNX implements the universal breakpoint protocol itself
                // (BreakpointJIT.framework / BreakpointHandler.swift) with
                // its own script — the same one StikEnableJIT.swift sends
                // to the external StikDebug app — rather than StikJIT's
                // bundled universal.js, so both JIT paths run the identical
                // protocol implementation. forceScript stays false (the
                // documented default): StikJIT does its own TXM detection
                // and only exercises the script when it's actually needed.
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(meloNXBreakpointScript),
                    forceScript: false,
                    preparationProgress: { stage in NSLog("[MeloNXJIT] prepare: %@", String(describing: stage)) },
                    progress: { line in NSLog("[MeloNXJIT] %@", line) }
                )
                return .init(success: true, message: "Detached.", txmPresent: StikJIT.isTXMPresent)

            case .resetDDI:
                preconditionFailure("handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription, txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in
/// the first input item's userInfo; the response goes back the same way in
/// the item this completes the request with.
@objc(MeloNXJITHelperHandler)
final class MeloNXJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[MeloNXJITHelperRequest.itemKey] as? Data

        MeloNXJITWork.queue.async {
            let response: MeloNXJITHelperRequest.Response
            if let data, let request = try? JSONDecoder().decode(MeloNXJITHelperRequest.self, from: data) {
                response = MeloNXJITWork.handle(request)
            } else {
                response = .init(success: false, message: "MeloNX's JIT helper received no request.", txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [MeloNXJITHelperRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
