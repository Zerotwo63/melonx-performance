//
//  SetupView.swift
//  MeloNX
//
//  Created by Stossy11 on 04/03/2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @State private var isImportingKeys = false
    @State private var isImportingFirmware = false
    @State private var showAlert = false
    @State private var showSkipAlert = false
    @State private var alertMessage = ""
    @State private var keysImported = false
    @State private var firmImported = false
    @State private var showMainSetup = false
    @AppStorage("MeloNXAppMode") private var appModeRaw: String = ""
    @AppStorage("skippedSetup") var skippedSetup: Bool = false
    @Binding var isInSetup: Bool
    
    let cool: LocalizedStringKey = "MeloNX has issues with Certificates and should not be used. Official Install Guides is [here](https://melonx.org)"
    
    var body: some View {
        Group {
            if showMainSetup {
                mainBody
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.blue.opacity(0.1),
                        Color.red.opacity(0.1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .overlay(content: { IconAnimation(showMainSetup: $showMainSetup)})
            }
        }
    }
    
    var mainBody: some View {
        iOSNav {
            ZStack {
                if UIDevice.current.systemName.contains("iPadOS") {
                    iPadSetupView()
                } else {
                    iPhoneSetupView()
                }
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .alert(isPresented: $showSkipAlert) {
            Alert(
                title: Text("Skip Setup?"),
                primaryButton: .destructive(Text("Skip")) {
                    Task { @MainActor in
                        skippedSetup = true
                        isInSetup = false
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .onChange(of: isImportingFirmware) { newValue in
            if newValue {
                FileImporterManager.shared.importFiles(types: [.folder, .zip]) { result in
                    handleFirmwareImport(result: result)
                }
                isImportingFirmware = false
            }
        }
        .onChange(of: isImportingKeys) { newValue in
            if newValue {
                FileImporterManager.shared.importFiles(types: [.item], allowMultiple: true) { result in
                    handleKeysImport(result: result)
                }
                isImportingKeys = false
            }
        }
        .onAppear {
            RyujinxBridge.initialize()
            isInSetup = true
            keysImported = Ryujinx.shared.checkIfKeysImported()

            let firmware = Ryujinx.shared.fetchFirmwareVersion()
            firmImported = (firmware == "" ? "0" : firmware) != "0"

            // Covers reopening this screen or relaunching the app with both
            // already imported from a previous session — finishSetupIfReady()
            // must run here too, not just from the import callbacks, since
            // nothing "changes" in that case to otherwise trigger it.
            finishSetupIfReady()
        }
    }

    // Bug 1 fix: keysImported/firmImported were tracked correctly, but
    // nothing ever re-evaluated them to advance the screen on its own — the
    // only way forward was the "Finish Setup" button (enabled, never
    // auto-tapped) or the hidden double-tap-"Welcome"-to-Skip gesture. This
    // runs after every import and on reappear, and advances by itself once
    // both are actually valid.
    private func finishSetupIfReady() {
        print("[SETUP] reevaluating onboarding state")
        let gate = OnboardingGate(keysValid: keysImported, firmwareValid: firmImported)
        print("[SETUP] current onboarding step = \(gate.currentStep)")
        print("[SETUP] requirements satisfied = \(gate.requirementsSatisfied)")

        guard gate.requirementsSatisfied else {
            print("[SETUP] advance blocked reason = \(gate.blockedReason ?? "unknown")")
            return
        }

        print("[SETUP] advancing to JIT")
        skippedSetup = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isInSetup = false
        }
    }

    @ViewBuilder
    private func iPadSetupView() -> some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.blue.opacity(0.1),
                        Color.red.opacity(0.1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                HStack(spacing: 40) {
                    if geometry.size.width > 800 {
                        VStack(alignment: .center, spacing: 20) {
                            Image(uiImage: UIImage(named: appIcon()) ?? UIImage())
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 200, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 40))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 40)
                                        .stroke(
                                            LinearGradient(
                                                gradient: Gradient(colors: [
                                                    .blue.opacity(0.6),
                                                    .red.opacity(0.6)
                                                ]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ),
                                            lineWidth: 2
                                        )
                                )
                                .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 6)
                                .onTapGesture {
                                    if MusicSelectorView.isPlaying {
                                        MusicSelectorView.stopMusic()
                                    } else {
                                        let mp3 = MusicSelectorView.getMP3s().first(where: { $0.builtIn })
                                        MusicSelectorView.playMusic(mp3)
                                    }
                                }
                                .onTapGesture(count: 2) {
                                    let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                    var sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                    if ProcessInfo.processInfo.isiOSAppOnMac {
                                        sharedurl = documentsUrl.absoluteString
                                    }
                                    if UIApplication.shared.canOpenURL(URL(string: sharedurl)!) {
                                        UIApplication.shared.open(URL(string: sharedurl)!, options: [:])
                                    }
                                }
                            
                            Text("Welcome to MeloNX")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .onTapGesture(count: 2) {
                                    showSkipAlert = true
                                }
                            
                            if shouldAsCopy && !isInLiveContainer.0 {
                                Text(cool)
                                    .font(.callout)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)
                            }
                            
                            Text("Set up your Nintendo Switch emulation environment by importing keys and firmware.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                                .onTapGesture {
                                    let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                    var sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                    if ProcessInfo.processInfo.isiOSAppOnMac {
                                        sharedurl = documentsUrl.absoluteString
                                    }
                                    if UIApplication.shared.canOpenURL(URL(string: sharedurl)!) {
                                        UIApplication.shared.open(URL(string: sharedurl)!, options: [:])
                                    }
                                }
                        }
                        .frame(maxWidth: 400)
                    }
                    
                    VStack(spacing: 20) {
                        setupStep(
                            title: "Import Keys",
                            description: "Add your encryption keys",
                            systemImage: "key.fill",
                            isCompleted: keysImported,
                            action: { isImportingKeys = true }
                        )
                        
                        setupStep(
                            title: "Add Firmware",
                            description: "Install Nintendo Switch firmware",
                            systemImage: "square.and.arrow.down",
                            isCompleted: firmImported,
                            isEnabled: keysImported,
                            action: { isImportingFirmware = true }
                        )
                        
                        Button(action: { isInSetup = false }) {
                            HStack {
                                Text("Finish Setup")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                firmImported && keysImported
                                    ? Color.blue
                                    : Color.blue.opacity(0.3)
                            )
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(!(firmImported && keysImported))
                    }
                    .frame(maxWidth: 500)
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    @ViewBuilder
    private func iPhoneSetupView() -> some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.1),
                    Color.red.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(uiImage: UIImage(named: appIcon()) ?? UIImage())
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                .blue.opacity(0.6),
                                                .red.opacity(0.6)
                                            ]),
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        lineWidth: 2
                                    )
                            )
                            .shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 4)
                            .padding(.top, 40)
                            .onTapGesture {
                                if MusicSelectorView.isPlaying {
                                    MusicSelectorView.stopMusic()
                                } else {
                                    let mp3 = MusicSelectorView.getMP3s().first(where: { $0.builtIn })
                                    MusicSelectorView.playMusic(mp3)
                                }
                            }
                            .onTapGesture(count: 2) {
                                let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                var sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                if ProcessInfo.processInfo.isiOSAppOnMac {
                                    sharedurl = documentsUrl.absoluteString
                                }
                                if UIApplication.shared.canOpenURL(URL(string: sharedurl)!) {
                                    UIApplication.shared.open(URL(string: sharedurl)!, options: [:])
                                }
                            }
                        
                        Text("Welcome to MeloNX")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .padding(.bottom, 20)
                            .onTapGesture(count: 2) {
                                showSkipAlert = true
                            }
                        
                        if shouldAsCopy && !isInLiveContainer.0 {
                            Text(cool)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .padding(.bottom, 20)
                        }

                        Button {
                            appModeRaw = MeloNXAppMode.controller.rawValue
                        } label: {
                            Label("Use this iPhone as Controller", systemImage: "iphone.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        setupStep(
                            title: "Import Keys",
                            description: "Add your encryption keys",
                            systemImage: "key.fill",
                            isCompleted: keysImported,
                            action: { isImportingKeys = true }
                        )
                        
                        setupStep(
                            title: "Add Firmware",
                            description: "Install Nintendo Switch firmware",
                            systemImage: "square.and.arrow.down",
                            isCompleted: firmImported,
                            isEnabled: keysImported,
                            action: { isImportingFirmware = true }
                        )
                    }
                    .padding()
                }
                
                // Finish Button
                VStack {
                    Button(action: { isInSetup = false }) {
                        HStack {
                            Text("Finish Setup")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            firmImported && keysImported
                                ? Color.blue
                                : Color.blue.opacity(0.3)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!(firmImported && keysImported))
                    .padding()
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func setupStep(
        title: String,
        description: String,
        systemImage: String,
        isCompleted: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(isCompleted ? .green : .blue)
                    .imageScale(.large)
                
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .disabled(!isEnabled || isCompleted)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    private func handleKeysImport(result: Result<[URL], Error>) {
        print("[SETUP] keys import started")
        do {
            let selectedFiles = try result.get()

            guard selectedFiles.count == 2 else {
                alertMessage = "Please select exactly 2 key files"
                showAlert = true
                print("[SETUP] keys import completed")
                print("[SETUP] keys valid = false")
                return
            }

            let fileManager = FileManager.default
            let systemDirectory = URL.documentsDirectory.appendingPathComponent("system")
            try fileManager.createDirectory(at: systemDirectory, withIntermediateDirectories: true)

            for fileURL in selectedFiles {
                // A document picker URL can already be directly readable (for
                // example when the picker gives us a copied/local URL). In that
                // case startAccessingSecurityScopedResource() legitimately
                // returns false, so it must not be treated as permission denied.
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }

                let destinationURL = systemDirectory.appendingPathComponent(fileURL.lastPathComponent)
                let data = try Data(contentsOf: fileURL)
                try data.write(to: destinationURL, options: .atomic)
            }

            keysImported = Ryujinx.shared.checkIfKeysImported()
            print("[SETUP] keys import completed")
            print("[SETUP] keys valid = \(keysImported)")

            guard keysImported else {
                alertMessage = "Keys were copied, but prod.keys was not found. Select the correct key files and try again."
                showAlert = true
                return
            }

            alertMessage = firmImported
                ? "Keys imported successfully"
                : "Keys imported successfully. Next, install the firmware. JIT is a separate requirement and is not enabled by Switch keys."
            showAlert = true
            finishSetupIfReady()

        } catch {
            print("[SETUP] keys import completed")
            print("[SETUP] keys valid = false")
            alertMessage = "Error importing keys: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func handleFirmwareImport(result: Result<[URL], Error>) {
        print("[SETUP] firmware import started")
        do {
            let selectedFiles = try result.get()

            guard let fileURL = selectedFiles.first else {
                alertMessage = "No file selected"
                showAlert = true
                print("[SETUP] firmware import completed")
                print("[SETUP] firmware valid = false")
                return
            }

            // Security-scoped access is optional: copied/local picker URLs are
            // readable even when startAccessingSecurityScopedResource() is false.
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let (string, isErr) = RyujinxBridge.installFirmware(at: fileURL.path)

            if isErr {
                print("[SETUP] firmware import completed")
                print("[SETUP] firmware valid = false")
                alertMessage = string.isEmpty ? "Firmware installation failed" : string
                showAlert = true
                return
            }

            Ryujinx.shared.firmwareversion = string
            firmImported = (string.isEmpty ? "0" : string) != "0"
            print("[SETUP] firmware import completed")
            print("[SETUP] firmware valid = \(firmImported)")

            alertMessage = firmImported
                ? "Firmware installed successfully"
                : "Firmware installation finished, but MeloNX could not detect an installed firmware version."
            showAlert = true
            finishSetupIfReady()

        } catch {
            print("[SETUP] firmware import completed")
            print("[SETUP] firmware valid = false")
            alertMessage = "Error importing firmware: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    func appIcon(in bundle: Bundle = .main) -> String {
        guard let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              
              let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
              
              let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
              
              let iconFileName = iconFiles.last else {

            // print("Could not find icons in bundle")
            return ""
        }

        return iconFileName
    }
}
