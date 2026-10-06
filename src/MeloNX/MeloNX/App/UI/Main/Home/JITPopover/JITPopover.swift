//
//  JITPopover.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI
import UIKit

struct JITPopover: View {
    var onJITEnabled: () -> Void
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var gameHandler: LaunchGameHandler

    @State private var isJIT: Bool = false
    @State private var pulseAnimation: Bool = false
    @State private var showFailedAlert: Bool = false
    @State private var showDiagnostics: Bool = false
    @State private var diagnosticsReport: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            // cool animation :3
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                    .opacity(pulseAnimation ? 0 : 1)
                    .animation(
                        Animation.easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: false),
                        value: pulseAnimation
                    )
                
                Image(systemName: "cpu.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
            .padding(.top, 10)
            
            VStack(spacing: 8) {
                Text("Waiting for JIT")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("Waiting for Just-In-Time compilation...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                    
                    Text("JIT compilation enables MeloNX to achieve maximum performance by dynamically translating and executing code on the fly.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                    
                    Text("This process is required for the emulator to function properly.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
        )
        .alert("JIT Not Acquired", isPresented: $showFailedAlert) {
            Button("Retry") {
                showFailedAlert = false
                JITCoordinator.shared.cancel()
                startWaiting()
            }
            Button("Copy JIT Diagnostics") {
                // Build exactly once, persist it in SwiftUI state, and also
                // put the same bytes on the pasteboard. The previous version
                // only wrote to UIPasteboard from the alert action; on the
                // physical iPhone that action dismissed the alert but left an
                // empty pasteboard, making the entire diagnostic path useless.
                //
                // Keeping a copy in-app means the report remains available
                // even if iOS/sideloading interferes with the pasteboard.
                let report = JITDiagnostics.buildReport()
                diagnosticsReport = report
                UIPasteboard.general.string = report
                JITCoordinator.shared.logDiag("[JIT] diagnostics copied to clipboard")

                // Present after the alert has finished dismissing. Trying to
                // present another modal in the same alert transaction can be
                // dropped by SwiftUI/UIKit on-device.
                DispatchQueue.main.async {
                    showDiagnostics = true
                }
            }
            Button("Cancel", role: .cancel) {
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text("MeloNX could not acquire JIT with the methods currently enabled in Settings.")
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                ScrollView {
                    Text(diagnosticsReport.isEmpty ? "[JIT DIAGNOSTICS]\nreport generation returned an empty string" : diagnosticsReport)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("JIT Diagnostics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showDiagnostics = false
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Copy") {
                            UIPasteboard.general.string = diagnosticsReport
                            JITCoordinator.shared.logDiag("[JIT] diagnostics copied to clipboard")
                        }
                        ShareLink(item: diagnosticsReport) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            pulseAnimation = true
            startWaiting()
        }
        .onDisappear {
            JITCoordinator.shared.cancel()
        }
    }

    // Was previously an uncapped poll (maxAttempts: 0, JITCoordinator's
    // default) with no reaction to failure at all — this screen could
    // only ever dismiss itself on success, so a real activation failure
    // left it spinning on "Waiting for JIT" forever with no feedback.
    // Capping it lets JITCoordinator actually reach `.timedOut`, and the
    // failure branch here surfaces that instead of hiding it.
    private func startWaiting() {
        JITCoordinator.shared.waitForJIT(
            trigger: { gameHandler.enableJIT() },
            maxAttempts: 60,
            interval: 0.5
        ) { success in
            isJIT = success

            if success {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    presentationMode.wrappedValue.dismiss()
                }
                onJITEnabled()
                Ryujinx.shared.checkForJIT()
            } else {
                showFailedAlert = true
            }
        }
    }
}
