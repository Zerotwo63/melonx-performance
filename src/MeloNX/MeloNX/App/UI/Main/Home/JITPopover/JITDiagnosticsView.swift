//
//  JITDiagnosticsView.swift
//  MeloNX
//

import SwiftUI
import UIKit

/// Replaces the old "Copy JIT Diagnostics" alert button. A SwiftUI .alert
/// dismisses the instant any button is tapped, with nowhere left to read
/// the result — this is a real sheet with the full report as selectable
/// text, so "did the copy actually work" stops being the only way to see
/// what happened.
///
/// Deliberately avoids bare SwiftUI.NavigationStack/ShareLink/
/// .presentationDetents — this project's actual build (confirmed by a
/// real CI failure: "error: 'NavigationStack' is only available in iOS
/// 16.0 or newer" / 'ShareLink' / 'presentationDetents', same message)
/// targets iOS 15, not the 18.1 an earlier comment elsewhere assumed.
/// Uses this project's own `iOSNav` wrapper (Ryujinx.swift) instead,
/// which already picks real NavigationStack on 16+ or
/// NavigationStackBackport on 15 — the established pattern for exactly
/// this, already used by SetupView. A UIActivityViewController wrapper
/// covers sharing, since ShareLink needs iOS 16.
struct JITDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: String = "Generating diagnostics..."
    @State private var showCopiedConfirmation = false
    @State private var showShareSheet = false

    var body: some View {
        iOSNav {
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("JIT Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Share") {
                        showShareSheet = true
                    }
                    Button("Copy") {
                        UIPasteboard.general.string = report
                        withAnimation { showCopiedConfirmation = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { showCopiedConfirmation = false }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showCopiedConfirmation {
                    copiedBanner
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityShareSheet(items: [report])
            }
        }
        .onAppear {
            // Also persists to Documents/jit-diagnostics.txt - the explicit
            // "don't lose the data even if the clipboard fails" requirement.
            report = JITDiagnostics.generateAndPersistReport()
        }
    }

    private var copiedBanner: some View {
        Text("Copied")
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.2))
            .cornerRadius(8)
            .transition(.opacity)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }
}

/// Plain UIActivityViewController wrapper — ShareLink needs iOS 16, which
/// this project's real deployment target predates.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
