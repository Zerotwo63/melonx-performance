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
    @State private var diagnosticsLog: [String] = []
    @State private var lastOnboardingState: OnboardingStep = .keys
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

            // Covers reopening this screen or relaunching the app with both
            // already imported from a previous session — this must run here
            // too, not just from the import callbacks, since nothing
            // "changes" in that case to otherwise trigger it.
            refreshAndEvaluate(trigger: "onAppear")
        }
    }

    // On-screen, visible-without-Xcode log for Bug A diagnosis. print()
    // alone is useless to someone testing on a real iPhone with no Mac —
    // this mirrors every line into a buffer the setup screen itself shows.
    private func diagLog(_ message: String) {
        print(message)
        diagnosticsLog.append(message)
        if diagnosticsLog.count > 300 {
            diagnosticsLog.removeFirst(diagnosticsLog.count - 300)
        }
    }

    // The single reevaluation path — onAppear, both import handlers, and
    // the manual "Reevaluate Now" diagnostic button all call this exact
    // function with nothing else in between. That's deliberate: if pressing
    // the button advances setup but the automatic call sites don't, the bug
    // is in *when* this runs, not in this function itself. If the button
    // also fails, the bug is upstream of this function (real state never
    // actually becomes true) and the diagnostics panel's "real" column
    // shows which of keys/firmware is actually responsible.
    private func refreshAndEvaluate(trigger: String) {
        diagLog("[SETUP] reevaluate called")
        diagLog("[SETUP] reevaluate trigger = \(trigger)")

        keysImported = Ryujinx.shared.checkIfKeysImported()
        let firmware = Ryujinx.shared.fetchFirmwareVersion()
        firmImported = (firmware == "" ? "0" : firmware) != "0"

        finishSetupIfReady()
    }

    // Bug A fix attempt #1 (180a6a684): keysImported/firmImported were
    // tracked correctly, but nothing ever re-evaluated them to advance the
    // screen on its own. On real-device testing that fix still did not
    // advance automatically — the diagnostics panel below exists to find
    // out why, rather than guess again.
    private func finishSetupIfReady() {
        let gate = OnboardingGate(keysValid: keysImported, firmwareValid: firmImported)

        diagLog("[SETUP] keys = \(keysImported)")
        diagLog("[SETUP] firmware = \(firmImported)")
        diagLog("[SETUP] requirementsSatisfied = \(gate.requirementsSatisfied)")

        if gate.currentStep != lastOnboardingState {
            diagLog("[SETUP] transition \(lastOnboardingState) -> \(gate.currentStep)")
            lastOnboardingState = gate.currentStep
        }

        guard gate.requirementsSatisfied else {
            diagLog("[SETUP] advance blocked reason = \(gate.blockedReason ?? "unknown")")
            return
        }

        diagLog("[SETUP] advancing to JIT")
        skippedSetup = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isInSetup = false
        }
    }

    // --- Diagnostics (temporary, for isolating Bug A on-device without Xcode) ---

    private struct KeysSnapshot {
        let found: Bool
        let path: String
        let realValidation: Bool
    }

    private struct FirmwareSnapshot {
        let contentFound: Bool
        let path: String
        let detectedVersion: String
        let realValidation: Bool
    }

    /// Queries the filesystem directly, independent of cached @State —
    /// hypothesis G/B material: if this disagrees with `keysImported`,
    /// the cached flag is stale (D) rather than the file genuinely missing.
    private func keysSnapshot() -> KeysSnapshot {
        let path = URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("prod.keys")
        let found = FileManager.default.fileExists(atPath: path.path)
        return KeysSnapshot(found: found, path: path.path, realValidation: Ryujinx.shared.checkIfKeysImported())
    }

    /// The real destination ContentManager.InstallFirmware writes to —
    /// traced through ContentPath.TryGetRealPath(SystemContent) + "registered"
    /// in Ryujinx.HLE/FileSystem/ContentPath.cs, with AppDataManager.BaseDirPath
    /// confirmed as Documents on iOS (Program.cs's `initialize` export calls
    /// AppDataManager.Initialize(Environment.SpecialFolder.MyDocuments)).
    /// Not a guess — read from the actual C# source this native call runs.
    private func canonicalFirmwareRegisteredPath() -> String {
        URL.documentsDirectory
            .appendingPathComponent("bis")
            .appendingPathComponent("system")
            .appendingPathComponent("Contents")
            .appendingPathComponent("registered")
            .path
    }

    /// The canonical path plus one plausible wrong guess, so a real-device
    /// test can rule out a path mismatch directly instead of trusting this
    /// session's source trace alone.
    private func candidateFirmwarePaths() -> [String] {
        [
            canonicalFirmwareRegisteredPath(),
            URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("Contents").appendingPathComponent("registered").path,
        ]
    }

    private func directoryStats(atPath path: String) -> (exists: Bool, count: Int) {
        let exists = FileManager.default.fileExists(atPath: path)
        let count = (try? FileManager.default.contentsOfDirectory(atPath: path))?.count ?? 0
        return (exists, count)
    }

    /// Two independent signals on purpose: `contentFound` reads the actual
    /// registered-content directory on disk, while `realValidation` goes
    /// through the same native bridge call the rest of the app trusts. If a
    /// user's device shows contentFound=true but realValidation=false, the
    /// native firmware version cache/bridge is the real bug, not SwiftUI.
    private func firmwareSnapshot() -> FirmwareSnapshot {
        let path = canonicalFirmwareRegisteredPath()
        let contentFound = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty == false
        let version = Ryujinx.shared.fetchFirmwareVersion()
        let realValidation = (version.isEmpty ? "0" : version) != "0"
        return FirmwareSnapshot(contentFound: contentFound, path: path, detectedVersion: version, realValidation: realValidation)
    }

    private func copyDiagnosticsToClipboard() {
        let keys = keysSnapshot()
        let firmware = firmwareSnapshot()
        let gate = OnboardingGate(keysValid: keysImported, firmwareValid: firmImported)

        var text = "MeloNX Setup Diagnostics\n"
        text += "KEYS: fileFound=\(keys.found) path=\(keys.path) realValidation=\(keys.realValidation)\n"
        text += "FIRMWARE: contentFound=\(firmware.contentFound) path=\(firmware.path) detectedVersion=\(firmware.detectedVersion) realValidation=\(firmware.realValidation)\n"
        text += "SETUP: hasKeys(cached)=\(keysImported) hasFirmware(cached)=\(firmImported) requirementsSatisfied=\(gate.requirementsSatisfied) step=\(gate.currentStep) blockedReason=\(gate.blockedReason ?? "none")\n"
        text += "LOG:\n" + diagnosticsLog.joined(separator: "\n")

        UIPasteboard.general.string = text
        diagLog("[SETUP] diagnostics copied to clipboard")
    }

    // Split into sections on purpose: a single VStack with this many direct
    // children would exceed SwiftUI's ViewBuilder arity limit and fail to
    // compile — each section function stays well under that on its own.
    @ViewBuilder
    private func diagnosticsPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics").font(.headline)
            diagnosticsKeysSection()
            diagnosticsFirmwareSection()
            diagnosticsCandidatePathsSection()
            diagnosticsSetupSection()
            diagnosticsActionButtons()
            diagnosticsLogSection()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func diagnosticsKeysSection() -> some View {
        let keys = keysSnapshot()
        VStack(alignment: .leading, spacing: 10) {
            Text("KEYS").font(.caption).bold().foregroundColor(.secondary)
            diagRow("file found", "\(keys.found)")
            diagRow("path", keys.path)
            diagRow("real validation", "\(keys.realValidation)")
        }
    }

    @ViewBuilder
    private func diagnosticsFirmwareSection() -> some View {
        let firmware = firmwareSnapshot()
        VStack(alignment: .leading, spacing: 10) {
            Text("FIRMWARE").font(.caption).bold().foregroundColor(.secondary)
            diagRow("content found", "\(firmware.contentFound)")
            diagRow("path", firmware.path)
            diagRow("detected version", firmware.detectedVersion.isEmpty ? "(none)" : firmware.detectedVersion)
            diagRow("real validation", "\(firmware.realValidation)")
        }
    }

    // Candidate-path sanity check (step 7 of the on-device diagnosis
    // request): path + exists + file count only, no full listings.
    @ViewBuilder
    private func diagnosticsCandidatePathsSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CANDIDATE PATHS").font(.caption).bold().foregroundColor(.secondary)
            ForEach(candidateFirmwarePaths(), id: \.self) { path in
                let stats = directoryStats(atPath: path)
                diagRow(path, "exists=\(stats.exists) files=\(stats.count)")
            }
        }
    }

    @ViewBuilder
    private func diagnosticsSetupSection() -> some View {
        let gate = OnboardingGate(keysValid: keysImported, firmwareValid: firmImported)
        VStack(alignment: .leading, spacing: 10) {
            Text("SETUP").font(.caption).bold().foregroundColor(.secondary)
            diagRow("hasKeys (cached)", "\(keysImported)")
            diagRow("hasFirmware (cached)", "\(firmImported)")
            diagRow("requirementsSatisfied", "\(gate.requirementsSatisfied)")
            diagRow("onboarding step", "\(gate.currentStep)")
            diagRow("blocked reason", gate.blockedReason ?? "none")
        }
    }

    @ViewBuilder
    private func diagnosticsActionButtons() -> some View {
        HStack {
            Button("Reevaluate Now") {
                refreshAndEvaluate(trigger: "manualButton")
            }
            .buttonStyle(.borderedProminent)

            Button("Copy Diagnostics") {
                copyDiagnosticsToClipboard()
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func diagnosticsLogSection() -> some View {
        if !diagnosticsLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Log").font(.caption).bold().foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(diagnosticsLog.indices, id: \.self) { index in
                            Text(diagnosticsLog[index])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
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
                    
                    ScrollView {
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

                            diagnosticsPanel()
                        }
                        .frame(maxWidth: 500)
                        .padding()
                    }
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

                        diagnosticsPanel()
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
        diagLog("[KEYS] importer completion")
        do {
            let selectedFiles = try result.get()

            guard selectedFiles.count == 2 else {
                alertMessage = "Please select exactly 2 key files"
                showAlert = true
                diagLog("[KEYS] real validation = false (wrong file count)")
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

            let realValidation = Ryujinx.shared.checkIfKeysImported()
            diagLog("[KEYS] real validation = \(realValidation)")

            refreshAndEvaluate(trigger: "keysImportHandler")

            guard keysImported else {
                alertMessage = "Keys were copied, but prod.keys was not found. Select the correct key files and try again."
                showAlert = true
                return
            }

            alertMessage = firmImported
                ? "Keys imported successfully"
                : "Keys imported successfully. Next, install the firmware. JIT is a separate requirement and is not enabled by Switch keys."
            showAlert = true

        } catch {
            diagLog("[KEYS] real validation = false (exception: \(error.localizedDescription))")
            alertMessage = "Error importing keys: \(error.localizedDescription)"
            showAlert = true
        }
    }

    // Root cause (confirmed by reading Ryujinx.Headless.SDL2/Program.cs,
    // not assumed): the native install call used to be
    // `Task.Run(() => _contentManager.InstallFirmware(filePath))` followed
    // immediately by `return systemVersion.VersionString` — the SOURCE
    // package's declared version, read by VerifyFirmwarePackage, which only
    // ever inspects the picked file/zip and never touches the destination.
    // That return happened long before the real extraction+copy into
    // registered/ was anywhere close to done, so "picker completion" and
    // "installation completion" were being treated as the same event when
    // they are not. Fixed on the C# side: InstallFirmware now blocks until
    // the real copy finishes and returns the destination's own verified
    // version (GetCurrentFirmwareVersion()) instead of the source's.
    //
    // That still leaves a real call that blocks for as long as extracting
    // a firmware package takes - calling it on the main thread here would
    // freeze the UI. Task.detached runs it off the main thread and this
    // function genuinely awaits its real result (no sleep, no asyncAfter,
    // no polling) before touching any @State.
    private func handleFirmwareImport(result: Result<[URL], Error>) {
        diagLog("[FIRMWARE] picker completed")
        do {
            let selectedFiles = try result.get()

            guard let fileURL = selectedFiles.first else {
                alertMessage = "No file selected"
                showAlert = true
                diagLog("[FIRMWARE] picker completed = false (no file selected)")
                return
            }

            // Security-scoped access is optional: copied/local picker URLs are
            // readable even when startAccessingSecurityScopedResource() is
            // false. Must stay alive for the entire install, not just this
            // synchronous function body - released only after the
            // background Task actually finishes reading the source file.
            let accessing = fileURL.startAccessingSecurityScopedResource()
            let sourcePath = fileURL.path
            diagLog("[FIRMWARE] source path = \(sourcePath)")

            let destinationPath = canonicalFirmwareRegisteredPath()
            let before = directoryStats(atPath: destinationPath)
            diagLog("[FIRMWARE] destination directory = \(destinationPath)")
            diagLog("[FIRMWARE] destination exists before = \(before.exists)")
            diagLog("[FIRMWARE] destination file count before = \(before.count)")

            diagLog("[FIRMWARE] installation started")

            Task.detached {
                let (string, isErr) = RyujinxBridge.installFirmware(at: sourcePath)

                if accessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }

                await MainActor.run {
                    diagLog("[FIRMWARE] installation completed = \(!isErr)")

                    let after = self.directoryStats(atPath: destinationPath)
                    diagLog("[FIRMWARE] destination exists after = \(after.exists)")
                    diagLog("[FIRMWARE] destination file count after = \(after.count)")
                    let firstFiles = (try? FileManager.default.contentsOfDirectory(atPath: destinationPath))?.prefix(5) ?? []
                    diagLog("[FIRMWARE] first destination files = \(Array(firstFiles))")

                    if isErr {
                        diagLog("[FIRMWARE] final validation = false (install error: \(string))")
                        self.alertMessage = string.isEmpty ? "Firmware installation failed" : string
                        self.showAlert = true
                        return
                    }

                    Ryujinx.shared.firmwareversion = string

                    let finalVersion = Ryujinx.shared.fetchFirmwareVersion()
                    let finalValidation = (finalVersion.isEmpty ? "0" : finalVersion) != "0"
                    diagLog("[FIRMWARE] final validation = \(finalValidation)")

                    self.refreshAndEvaluate(trigger: "firmwareImportHandler")

                    self.alertMessage = self.firmImported
                        ? "Firmware installed successfully"
                        : "Firmware installation finished, but MeloNX could not detect an installed firmware version."
                    self.showAlert = true
                }
            }

        } catch {
            diagLog("[FIRMWARE] picker completed = false (exception: \(error.localizedDescription))")
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
