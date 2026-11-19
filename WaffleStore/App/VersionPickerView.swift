import SwiftUI
import MapleSAP

struct VersionPickerEntry: Identifiable, Hashable {
    var id: String { externalVersionID }
    let externalVersionID: String
    let bundleVersion: String?

    var titleText: String {
        if let bundleVersion, !bundleVersion.isEmpty {
            return "Version \(bundleVersion)"
        }
        return "Build \(externalVersionID)"
    }
}

struct VersionPickerState: Identifiable {
    let id = UUID()
    let app: StoreApp
    let tool: IPATool
    let entries: [VersionPickerEntry]
    let installedVersion: String?
    let mapleErrorMessage: String?
}

struct VersionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appData: AppData

    enum InstallMethod: Int, CaseIterable {
        case appleStore = 0
        case downloadIPA = 1
    }

    let state: VersionPickerState
    @State private var query: String = ""
    @State private var installMethod: InstallMethod = .appleStore
    @State private var showManualBuildAlert = false
    @State private var manualBuildID: String = ""

    private func triggerSelection(extID: String, verLabel: String) {
        let chosenMode = installMethod
        dismiss()
        appData.versionPickerState = nil
        if chosenMode == .downloadIPA {
            appData.isDowngrading = true
            appData.download(app: state.app, version: extID, tool: state.tool, installWhenReady: false)
        } else {
            appData.applicationStatus = "Sending request to App Store..."
            appData.hasAppBeenServed = false
            let appRef = state.app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                WaffleInstallViaAppleStore(appRef.id, extID) { ok, errMsg in
                    Task { @MainActor in
                        if ok {
                            appData.applicationStatus = "Sent \(appRef.name) to App Store!"
                            appData.hasAppBeenServed = true
                            appData.applicationIcon = "checkmark.circle.fill"
                            WafflePresentAlert(
                                "Apple Store Install Requested",
                                "\(appRef.name) (\(verLabel), Build \(extID)) was sent to iOS App Store daemon (itunesstored/appstored). Check your Home Screen for download progress."
                            )
                        } else {
                            appData.applicationStatus = "Apple install failed."
                            appData.applicationIcon = "xmark.circle.fill"
                            WafflePresentAlert(
                                "Apple Install Failed",
                                errMsg ?? "Unknown error"
                            )
                        }
                    }
                }
            }
        }
    }

    private var filteredEntries: [VersionPickerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return state.entries }
        return state.entries.filter {
            $0.externalVersionID.localizedCaseInsensitiveContains(q) ||
            ($0.bundleVersion?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let installed = state.installedVersion {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                        Text("Installed on device: v\(installed)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                }

                Picker("Install Mode", selection: $installMethod) {
                    Text("Install via Apple (Recommended)").tag(InstallMethod.appleStore)
                    Text("Download .IPA").tag(InstallMethod.downloadIPA)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if let mapleErr = state.mapleErrorMessage, !mapleErr.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: installMethod == .appleStore ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(installMethod == .appleStore ? .blue : .orange)
                        Text(installMethod == .appleStore
                             ? "Apple Store native install active (session token bypass)."
                             : "Session expired (2034): Log Out & Sign In in Account to download .IPA.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)
                }

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search version or Build ID...", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button(action: { query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Button {
                    manualBuildID = ""
                    showManualBuildAlert = true
                } label: {
                    HStack {
                        Image(systemName: "number.square")
                        Text("Enter Build ID Manually...")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if filteredEntries.isEmpty {
                    Spacer()
                    Text("No cached version history found.\nUse 'Enter Build ID Manually...' above.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List(filteredEntries) { entry in
                        Button {
                            triggerSelection(extID: entry.externalVersionID, verLabel: entry.titleText)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.titleText)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text("Build ID: \(entry.externalVersionID)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if let installed = state.installedVersion,
                                   let bv = entry.bundleVersion,
                                   installed == bv || installed.hasPrefix("\(bv) ") {
                                    Text("Installed")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundColor(.blue)
                                        .cornerRadius(4)
                                }
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(state.app.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel".localized) {
                        dismiss()
                        appData.versionPickerState = nil
                        resetDowngradeProgress()
                    }
                }
            }
            .alert("Enter Build ID", isPresented: $showManualBuildAlert) {
                TextField("e.g. 861234567", text: $manualBuildID)
                    .keyboardType(.numberPad)
                Button("Install") {
                    let clean = manualBuildID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        triggerSelection(extID: clean, verLabel: "Build \(clean)")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter external_identifier for \(state.app.name)")
            }
        }
    }
}
