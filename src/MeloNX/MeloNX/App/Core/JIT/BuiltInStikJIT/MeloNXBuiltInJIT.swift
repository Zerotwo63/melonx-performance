//
//  MeloNXBuiltInJIT.swift
//  MeloNX
//

import Foundation

/// The private NSExtension API (ExtensionFoundation) that starts an app
/// extension of MeloNX's own — the same calls LiveContainer uses to start
/// its LiveProcess. Needed because the "classic app extension" mechanism
/// MeloNXJITHelper registers under (com.apple.ar.viewer,
/// NSExtensionActivationRule = FALSEPREDICATE — see
/// MeloNXJITHelper/Info.plist) has no public start-this-extension API.
/// Not App Store-safe; consistent with the rest of this build
/// (SecTaskCopyValueForEntitlement in EntitlementChecker.swift is the
/// same category of private SPI, and this app ships only as a sideload).
@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// Starts MeloNXJITHelper.appex — the separate process required to debug
/// MeloNX without MeloNX deadlocking on itself — and sends it one request.
/// Not wired into LaunchGameHandler/SettingsView yet: that's a live
/// behavior change to the JIT-method picker, and Built-in StikJIT can't
/// actually succeed until pairing-file import (a separate, later piece)
/// exists for BuiltInStikJITAvailability.hasImportedPairingFile to find
/// anything. This file is the real, callable launcher on its own —
/// verifiable by CI (compiles, matches the real private API shape) even
/// though exercising it end-to-end needs a real pairing file and a
/// physical device, neither of which CI has.
@MainActor
enum MeloNXBuiltInJIT {
    /// Requests that have started and not finished, kept alive until they do.
    private static var running: [HelperRequest] = []

    static func send(
        _ request: MeloNXJITHelperRequest,
        started: @escaping () -> Void = {},
        completion: @escaping (Result<MeloNXJITHelperRequest.Response, Error>) -> Void
    ) {
        func fail(_ code: Int, _ message: String) {
            print("[jit-helper] \(message)")
            completion(.failure(NSError(domain: "MeloNXBuiltInJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])))
        }

        if let reason = BuiltInStikJITAvailability.unavailableReason() {
            fail(1, "Built-in StikJIT is unavailable: \(reason)")
            return
        }
        guard let identifier = BuiltInStikJITAvailability.helperIdentifier else {
            fail(2, "MeloNX's JIT helper is missing from this installation. Reinstall MeloNX, and keep its app extensions if your sideloader asks.")
            return
        }

        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, "iOS did not provide the extension API MeloNX's JIT helper needs.")
            return
        }

        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found: AnyObject
        do {
            found = try factory.extension(withIdentifier: identifier)
        } catch {
            fail(2, "MeloNX's JIT helper (\(identifier)) could not be found: \(error.localizedDescription) Reinstall MeloNX.")
            return
        }

        guard let data = try? JSONEncoder().encode(request) else {
            fail(4, "The request for MeloNX's JIT helper could not be encoded.")
            return
        }

        let helper = HelperRequest(extension: found, operation: request.operation.rawValue, completion: completion)
        running.append(helper)
        helper.begin(data: data, identifier: identifier, started: started)
    }

    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }

    /// LaunchGameHandler.enableJIT()'s Built-in StikJIT branch calls this
    /// and awaits a real result — a successful StikJIT.enableJIT() leaves
    /// CS_DEBUGGED set on this process, which JITCoordinator's isJITEnabled()
    /// poll (already driving JITPopover and checkJITAndRunGame) observes
    /// independently. This function's return value does NOT set `.acquired`
    /// itself — it only reports whether the helper's own attempt succeeded,
    /// so callers can log a real reason instead of guessing.
    ///
    /// Root cause of "never completes" (verified by reading this file, not
    /// assumed): the old version fired `.enable` directly and returned
    /// immediately, never calling `.prepare` first. `.prepare` is the
    /// operation that gets StikJIT a usable Developer Disk Image — on a
    /// fresh install with no cached DDI (StikDebug was never installed to
    /// prime one), `.enable` alone has nothing to work with. `.prepare` now
    /// runs first and must report `success` before `.enable` is attempted.
    static func enableCurrentProcess() async -> Bool {
        print("[JIT] enableCurrentProcess called")

        guard let pairingData = try? Data(contentsOf: BuiltInStikJITAvailability.pairingFileURL) else {
            print("[JIT] failed reason = could not read the imported pairing file")
            return false
        }

        let prepareRequest = MeloNXJITHelperRequest(operation: .prepare, targetPID: nil, pairingData: pairingData)
        switch await sendAsync(prepareRequest) {
        case .success(let response) where response.success:
            break
        case .success(let response):
            print("[JIT] failed reason = prepare failed: \(response.message)")
            return false
        case .failure(let error):
            print("[JIT] failed reason = prepare request failed: \(error.localizedDescription)")
            return false
        }

        let enableRequest = MeloNXJITHelperRequest(operation: .enable, targetPID: Int32(getpid()), pairingData: pairingData)
        switch await sendAsync(enableRequest) {
        case .success(let response):
            if !response.success {
                print("[JIT] failed reason = \(response.message)")
            }
            return response.success
        case .failure(let error):
            print("[JIT] failed reason = \(error.localizedDescription)")
            return false
        }
    }

    private static func sendAsync(_ request: MeloNXJITHelperRequest) async -> Result<MeloNXJITHelperRequest.Response, Error> {
        await withCheckedContinuation { continuation in
            send(request) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

/// One request to the helper, from its start to its one result.
@MainActor
private final class HelperRequest {
    private let shim: NSExtensionShim
    private let `extension`: AnyObject // the NSExtension, kept alive for the request
    private let operation: String
    private var completion: ((Result<MeloNXJITHelperRequest.Response, Error>) -> Void)?

    init(
        extension found: AnyObject,
        operation: String,
        completion: @escaping (Result<MeloNXJITHelperRequest.Response, Error>) -> Void
    ) {
        self.extension = found
        self.shim = unsafeBitCast(found, to: NSExtensionShim.self)
        self.operation = operation
        self.completion = completion
    }

    func begin(data: Data, identifier: String, started: @escaping () -> Void) {
        // The blocks can arrive on any queue; everything below runs on the main thread.
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[MeloNXJITHelperRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returned(payload) } }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "the request was cancelled"
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(5, "MeloNX's JIT helper stopped: \(message)")))
            } }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(6, "MeloNX's JIT helper stopped unexpectedly. Try again.")))
            } }
        }

        let item = NSExtensionItem()
        item.userInfo = [MeloNXJITHelperRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                guard let uuid else {
                    self.end(.failure(Self.error(7, "MeloNX's JIT helper did not start. Reinstall MeloNX, and keep its app extensions if your sideloader asks.")))
                    return
                }
                print("[jit-helper] \(self.operation): started \(identifier) as pid \(self.shim.pid(forRequestIdentifier: uuid))")
                started()
            } }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload, let response = try? JSONDecoder().decode(MeloNXJITHelperRequest.Response.self, from: payload) else {
            end(.failure(Self.error(8, "MeloNX's JIT helper finished without an answer.")))
            return
        }
        print("[jit-helper] \(operation): finished success=\(response.success ? 1 : 0)")
        end(.success(response))
    }

    private func end(_ result: Result<MeloNXJITHelperRequest.Response, Error>) {
        guard let completion else { return } // the first result counts
        self.completion = nil
        if case .failure(let error) = result {
            print("[jit-helper] \(operation): \(error.localizedDescription)")
        }
        MeloNXBuiltInJIT.finished(self)
        completion(result)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MeloNXBuiltInJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
