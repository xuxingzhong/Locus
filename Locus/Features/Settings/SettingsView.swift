import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var showNameEasterEgg = false
    @State private var showRealLocationEditor = false
    @StateObject private var realLocation = RealLocationStore.shared
    @AppStorage(RealLocationStore.smoothRestoreKey) private var useNearbyRestore = true
    @State private var tunnelIP = TunnelConfig.targetIP
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @State private var diagnosticVPNConnected = LocalDevVPN.isConnected
    @State private var diagnosticPort = LocationEngine.lastRemotePairingPort
    @State private var diagnosticRefreshing = false
    @StateObject private var updates = UpdateManager.shared
    @State private var updateAlert = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.system.rawValue

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Language") {
                    Picker("Language", selection: $languageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName)
                                .tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    Label {
                        Text(LocalizedStringKey(pairing.hasPairingFile ? "RPPairing file installed" : "No pairing file"))
                    } icon: {
                        Image(systemName: pairing.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }

                    if supportsOnDevicePairing {
                        Button {
                            showPairOnDevice = true
                        } label: {
                            Label("Pair on this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        }
                    }

                    Button("Import RPPairing file…") { showImporter = true }
                    Button("Paste RPPairing from clipboard") {
                        do {
                            try pairing.importPairingFromClipboard()
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    }
                    if pairing.hasPairingFile {
                        Button("Remove pairing file", role: .destructive) {
                            try? pairing.removePairing()
                        }
                    }
                } header: {
                    Text("Developer pairing")
                } footer: {
                    Text(supportsOnDevicePairing
                         ? "On iOS 27, use Pair on this iPhone — no computer. Locus advertises a pairable host; confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host. On older iOS, import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). LiveContainer: enable Fix File Picker on Locus, or use Paste / Share → LiveContainer → Locus."
                         : "Import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). If the file picker fails (common in LiveContainer), enable Fix File Picker on the app, share the file into LiveContainer → Locus, or copy the plist and use Paste.")
                }

                Section {
                    TextField("Device tunnel IP", text: $tunnelIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            TunnelConfig.setTargetIP(tunnelIP)
                        }
                    LabeledContent("Status") {
                        Text(LocalizedStringKey(LocalDevVPN.isConnected ? "Connected" : "Not connected"))
                            .foregroundStyle(LocalDevVPN.isConnected ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }
                    LabeledContent("Remote Pairing Port") {
                        Text(LocationEngine.lastRemotePairingPort.map(String.init) ?? "Not discovered yet")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Save tunnel IP") {
                        TunnelConfig.setTargetIP(tunnelIP)
                    }
                    Button {
                        if localDevVPNInstalled {
                            LocalDevVPN.openInstalled()
                        } else {
                            LocalDevVPN.openAppStore()
                        }
                    } label: {
                        Label(
                            localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN (App Store)",
                            systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                        )
                    }
                } header: {
                    Text("Tunnel")
                } footer: {
                    Text("LocalDevVPN configuration hint")
                }

                Section {
                    LabeledContent("Latest confirmed real location") {
                        Text(realLocation.saved?.address ?? String(localized: "Not saved"))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                    }
                    LabeledContent("Manual backup location") {
                        Text(realLocation.manualBackup?.address ?? String(localized: "Not set"))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                    }
                    if let snapshot = realLocation.saved {
                        LabeledContent(snapshot.source == .manual
                                       ? "Manually selected" : "Automatically captured") {
                            Text(snapshot.capturedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                        Text(LocalizedStringKey(realLocation.canUseForRecovery
                             ? "Usable for nearby restore"
                             : "Expired snapshot — choose a location or recapture"))
                            .font(.footnote)
                            .foregroundStyle(realLocation.canUseForRecovery
                                             ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    } else {
                        Text("Not yet trusted for nearby restore")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showRealLocationEditor = true
                    } label: {
                        Label("Search or edit real location", systemImage: "mappin.and.ellipse")
                    }

                    Button {
                        realLocation.requestFreshCapture()
                    } label: {
                        if realLocation.isLocating {
                            HStack {
                                ProgressView()
                                Text("Capturing precise location…")
                            }
                        } else {
                            Label("Capture current real position", systemImage: "location.circle")
                        }
                    }
                    .disabled(
                        !realLocation.isSafeToCapture || realLocation.isLocating
                        || session.isSpoofing || session.isBusy
                        || LocationEngine.isSessionActive
                    )

                    if let captureMessage = realLocation.captureMessage {
                        Text(captureMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Try one nearby transition when locations oscillate", isOn: $useNearbyRestore)
                } header: {
                    Text("Real location for recovery")
                } footer: {
                    Text("After confirming a fresh real position, recovery always briefly re-applies it and clears simulation once more. The toggle only controls an extra rescue for oscillating locations. Manual backup is never used automatically.")
                }

                Section("Connection Diagnostics") {
                    LabeledContent("RPPairing") {
                        diagnosticValue(pairing.hasPairingFile, ready: "Ready", notReady: "Missing")
                    }
                    LabeledContent("LocalDevVPN") {
                        diagnosticValue(diagnosticVPNConnected, ready: "Connected", notReady: "Not connected")
                    }
                    LabeledContent("Tunnel IP", value: TunnelConfig.targetIP)
                    LabeledContent("Remote Pairing Port") {
                        Text(diagnosticPort.map(String.init) ?? String(localized: "Not discovered yet"))
                            .font(.body.monospacedDigit())
                    }
                    LabeledContent("Developer Tunnel") {
                        diagnosticValue(LocationEngine.isSessionActive, ready: "Active", notReady: "Inactive")
                    }
                    Button {
                        refreshDiagnostics()
                    } label: {
                        if diagnosticRefreshing {
                            HStack {
                                ProgressView()
                                Text("Checking…")
                            }
                        } else {
                            Label("Run Diagnostics", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(diagnosticRefreshing)
                }

                Section {
                    Button {
                        // Works even after the normal restore button has
                        // disappeared: issue a new standalone DVT clear.
                        session.stop(pairing: pairing)
                    } label: {
                        Label("Clear Simulated Location Again", systemImage: "location.slash")
                    }
                    .disabled(
                        !pairing.hasPairingFile
                        || !diagnosticVPNConnected
                        || session.isBusy
                        || session.status == .restoring
                        || session.status == .waitingForRealLocation
                    )
                    if let manual = realLocation.manualBackup {
                        Button {
                            session.stop(pairing: pairing, useManualBackup: true)
                        } label: {
                            Label("Restore using manual backup", systemImage: "mappin.and.ellipse")
                        }
                        .disabled(
                            !pairing.hasPairingFile || !diagnosticVPNConnected
                            || session.isBusy
                            || session.status == .restoring
                            || session.status == .waitingForRealLocation
                        )
                        Text(manual.address)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let detail = session.restoreDetail {
                        Text(LocalizedStringKey(detail))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if case .restoreFailed(let reason) = session.status {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Location Recovery")
                } footer: {
                    Text("Normal restore never guesses a real coordinate. Manual backup is an explicit fallback and can be stale; Locus cannot reset other apps' own caches.")
                }

                Section {

                    LabeledContent("Current Version", value: appVersion)
                    if let release = updates.latestRelease {
                        LabeledContent("Latest Version", value: release.version)
                        if updates.hasUpdate {
                            Button {
                                updateAlert = true
                            } label: {
                                Label("Update Now", systemImage: "arrow.down.circle.fill")
                            }
                            .disabled(session.isBusy)
                        } else {
                            Label("Locus is up to date", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(LocusTheme.statusGood)
                        }
                    }
                    Button {
                        Task { await updates.check() }
                    } label: {
                        if updates.isChecking {
                            HStack { ProgressView(); Text("Checking for Updates…") }
                        } else {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(updates.isChecking)
                    if let error = updates.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Software Update")
                } footer: {
                    Text("Updates are installed by SideStore. Locus releases its developer tunnel before opening SideStore so the installer can connect reliably.")
                }

                Section("Privacy") {
                    Text("Location waypoints, favorites and recents stay in UserDefaults. Address lookup and place search use Apple's location and map services. No Locus analytics or accounts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Engine", value: "idevice DVT location simulation")
                    Text("Locus is free and open source (MIT). Location injection uses the MIT-licensed idevice FFI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showNameEasterEgg = true
                    } label: {
                        Text("locus, n. — a place. From the Latin for where you are.")
                            .font(.footnote.italic())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Settings")
            .alert("Update Locus", isPresented: $updateAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Prepare & Open SideStore") {
                    Task { await installLatestUpdate() }
                }
            } message: {
                if let release = updates.latestRelease {
                    Text(String(format: String(localized: "Update available format"), release.version))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        TunnelConfig.setTargetIP(tunnelIP)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
            .sheet(isPresented: $showRealLocationEditor) {
                RealLocationEditorView()
            }
            .sheet(isPresented: $showPairOnDevice) {
                PairOnDeviceView()
                    .environmentObject(pairing)
            }
            .fullScreenCover(isPresented: $showNameEasterEgg) {
                LocusEasterEggView()
            }
            .onAppear {
                localDevVPNInstalled = LocalDevVPN.isInstalled
                diagnosticVPNConnected = LocalDevVPN.isConnected
                diagnosticPort = LocationEngine.lastRemotePairingPort
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    localDevVPNInstalled = LocalDevVPN.isInstalled
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticValue(_ value: Bool, ready: LocalizedStringKey, notReady: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(value ? LocusTheme.statusGood : LocusTheme.statusWarn)
            Text(value ? ready : notReady)
        }
    }

    private func installLatestUpdate() async {
        guard let release = updates.latestRelease,
              let sideStoreURL = updates.sideStoreInstallURL(for: release) else { return }

        let result = await session.prepareForUpdate(pairing: pairing)
        switch result {
        case .success:
            // Give the FFI/tunnel teardown a brief chance to settle before
            // SideStore opens its own device gateway.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await UIApplication.shared.open(sideStoreURL)
        case .failure(let error):
            session.lastError = error.localizedDescription
        }
    }

    private func refreshDiagnostics() {
        diagnosticVPNConnected = LocalDevVPN.isConnected
        diagnosticRefreshing = true
        Task {
            let port = await Task.detached(priority: .userInitiated) {
                LocationEngine.refreshRemotePairingPort()
            }.value
            diagnosticPort = port ?? LocationEngine.lastRemotePairingPort
            diagnosticVPNConnected = LocalDevVPN.isConnected
            diagnosticRefreshing = false
        }
    }
}

struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    if session.favorites.isEmpty {
                        Text("Star a pin from the map to save it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                Section("Recents") {
                    if session.recents.isEmpty {
                        Text("Teleports show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    placeToRename = nil
                }
                Button("Save") {
                    if let place = placeToRename {
                        session.renameFavorite(place, to: renameText)
                    }
                    placeToRename = nil
                }
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
        }
    }

    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate, pairing: pairing)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
