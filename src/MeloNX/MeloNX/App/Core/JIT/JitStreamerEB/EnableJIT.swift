//
//  EnableJIT.swift
//  MeloNX
//

import Foundation
import Network
import UIKit

/// MeloNX's internal JIT activation path — needs no app installed
/// on-device beyond the existing "LocalDevVPN" tunnel (no StikDebug, no
/// spent AltStore slot). Verified against the real jkcoxson/JitStreamer-EB
/// project (its README, not assumed): it hands a device a WireGuard
/// config that routes fd00::/64 to a server reachable at exactly
/// fd00::9172 — the same address this file already targeted. The
/// VPN/server side is owned by LocalDevVPN + whatever JitStreamer-EB
/// instance it's configured against; this file is only the HTTP client
/// for the `/attach/<pid>` endpoint that project documents.
///
/// This was fully implemented but never called from anywhere —
/// LaunchGameHandler.enableJIT() now calls `JITStreamerEB.attach()` as
/// the first, internal attempt before falling back to
/// TrollStore/StikDebug/Built-in StikJIT.
enum JITStreamerEB {
    struct AttachResult: Codable {
        let success: Bool
        let message: String
    }

    /// Attempts to acquire JIT for the current process via the
    /// LocalDevVPN-reachable JitStreamer EB server. Returns whether it
    /// actually succeeded — callers decide whether to fall back.
    static func attach(requestTimeout: TimeInterval = 5, vpnWaitTimeout: TimeInterval = 30) async -> Bool {
        print("[JIT] internal method selected")

        if UserDefaults.standard.bool(forKey: "waitForVPN") {
            guard await waitForVPNConnection(timeout: vpnWaitTimeout) else {
                print("[JIT] timed out")
                return false
            }
        }

        print("[JIT] waiting")

        guard let result = await requestAttach(timeout: requestTimeout) else {
            print("[JIT] timed out")
            return false
        }

        if result.success {
            print("[JIT] acquired")
            await MainActor.run {
                Ryujinx.shared.checkForJIT()
            }
        } else {
            print("[JIT] timed out")
            let message = result.message
            Task { @MainActor in
                presentAlert(title: "JIT Error", message: message)
            }
        }

        return result.success
    }

    private static func requestAttach(timeout: TimeInterval) async -> AttachResult? {
        guard let url = URL(string: "http://[fd00::]:9172/attach/\(getpid())") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(AttachResult.self, from: data)
        } catch {
            print("[JIT] internal method request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func waitForVPNConnection(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await pingSite() {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        return false
    }

    private static func pingSite(host: String = "http://[fd00::]:9172/hello") async -> Bool {
        guard let url = URL(string: host) else { return false }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

func presentAlert(title: String, message: String, imageName: String? = nil, completion: (() -> Void)? = nil) {
    guard let rootVC = AppDelegate.window?.rootViewController else { return }

    if let imageName = imageName, UIImage(named: imageName) != nil {
        let customAlert = MacClassicAlertViewController(title: title, message: message, imageName: imageName, completion: completion)
        Task { @MainActor in
            rootVC.present(customAlert, animated: true)
        }
    } else {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completion?()
        })
        Task { @MainActor in
            rootVC.present(alert, animated: true)
        }
    }
}
