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
}

struct VersionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appData: AppData

    let state: VersionPickerState
    @State private var query: String = ""

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

                List(filteredEntries) { entry in
                    Button {
                        dismiss()
                        appData.versionPickerState = nil
                        appData.isDowngrading = true
                        appData.download(app: state.app, version: entry.externalVersionID, tool: state.tool, installWhenReady: true)
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
        }
    }
}
