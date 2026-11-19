import Foundation
import SwiftUI
import UIKit
import ObjectiveC.runtime

struct InstalledAppInfo: Identifiable, Hashable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let shortVersion: String
    let buildVersion: String
    let icon: UIImage?

    var displayVersion: String {
        if !shortVersion.isEmpty && !buildVersion.isEmpty && shortVersion != buildVersion {
            return "\(shortVersion) (\(buildVersion))"
        }
        return shortVersion.isEmpty ? (buildVersion.isEmpty ? "?" : buildVersion) : shortVersion
    }
}

enum InstalledAppsManager {
    static func fetchInstalledApps() -> [InstalledAppInfo] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return []
        }
        let defaultSel = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultSel),
              let workspace = workspaceClass.perform(defaultSel)?.takeUnretainedValue() as? NSObject else {
            return []
        }

        let allSel = NSSelectorFromString("allInstalledApplications")
        let fallbackSel = NSSelectorFromString("allApplications")
        var rawApps: [AnyObject] = []
        if workspace.responds(to: allSel),
           let list = workspace.perform(allSel)?.takeUnretainedValue() as? [AnyObject] {
            rawApps = list
        } else if workspace.responds(to: fallbackSel),
                  let list = workspace.perform(fallbackSel)?.takeUnretainedValue() as? [AnyObject] {
            rawApps = list
        }

        var apps: [InstalledAppInfo] = []
        for obj in rawApps {
            guard let proxy = obj as? NSObject else { continue }
            let appType = (proxy.value(forKey: "applicationType") as? String) ?? ""
            if !appType.isEmpty && appType != "User" {
                continue
            }
            let bundleID = (proxy.value(forKey: "applicationIdentifier") as? String)
                ?? (proxy.value(forKey: "bundleIdentifier") as? String)
                ?? ""
            guard !bundleID.isEmpty else { continue }

            let name = (proxy.value(forKey: "localizedName") as? String)
                ?? (proxy.value(forKey: "itemName") as? String)
                ?? bundleID
            let shortVersion = (proxy.value(forKey: "shortVersionString") as? String) ?? ""
            let buildVersion = (proxy.value(forKey: "bundleVersion") as? String) ?? ""
            let icon = loadIcon(for: bundleID)

            apps.append(InstalledAppInfo(
                name: name,
                bundleID: bundleID,
                shortVersion: shortVersion,
                buildVersion: buildVersion,
                icon: icon
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func installedVersion(for bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        return fetchInstalledApps().first(where: { $0.bundleID == bundleID })?.displayVersion
    }

    private static func loadIcon(for bundleID: String) -> UIImage? {
        let sel = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        guard UIImage.responds(to: sel),
              let method = class_getClassMethod(UIImage.self, sel) else {
            return nil
        }
        typealias Fn = @convention(c) (AnyClass, Selector, NSString, Int32, CGFloat) -> Unmanaged<UIImage>?
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(UIImage.self, sel, bundleID as NSString, 2, UIScreen.main.scale)?.takeUnretainedValue()
    }

    static func lookupAppStoreURL(forBundleID bundleID: String) async throws -> String {
        guard let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)&limit=1&media=software") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let trackViewUrl = first["trackViewUrl"] as? String else {
            throw NSError(domain: "WaffleStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "App not found on the App Store for bundle ID: \(bundleID)"])
        }
        return trackViewUrl
    }

    static func installIPA(at fileURL: URL, bundleID: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // Stage in a world-readable temp directory (just like appinst) so installd can read and consume the IPA
            let stageDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("wafflestore-install-\(UUID().uuidString)", isDirectory: true)
            var stagedIPA = fileURL
            var cleanupDir: URL? = nil

            if (try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])) != nil {
                let candidate = stageDir.appendingPathComponent("install.ipa")
                if (try? fm.copyItem(at: fileURL, to: candidate)) != nil {
                    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidate.path)
                    stagedIPA = candidate
                    cleanupDir = stageDir
                }
            }
            defer {
                if let cleanupDir {
                    try? fm.removeItem(at: cleanupDir)
                }
            }

            guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
                throw NSError(domain: "WaffleStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "LSApplicationWorkspace unavailable"])
            }
            let defaultSel = NSSelectorFromString("defaultWorkspace")
            guard workspaceClass.responds(to: defaultSel),
                  let workspace = workspaceClass.perform(defaultSel)?.takeUnretainedValue() else {
                throw NSError(domain: "WaffleStore", code: -2, userInfo: [NSLocalizedDescriptionKey: "defaultWorkspace unavailable"])
            }

            let installSel = NSSelectorFromString("installApplication:withOptions:error:")
            guard workspace.responds(to: installSel),
                  let method = class_getInstanceMethod(object_getClass(workspace), installSel) else {
                throw NSError(domain: "WaffleStore", code: -3, userInfo: [NSLocalizedDescriptionKey: "installApplication:withOptions:error: unavailable"])
            }

            typealias InstallFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary?, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: InstallFn.self)

            var outError: NSError?
            let options: NSDictionary = bundleID.isEmpty ? [:] : ["CFBundleIdentifier": bundleID]
            let ok = fn(workspace, installSel, stagedIPA as NSURL, options, &outError)
            if !ok.boolValue {
                throw outError ?? NSError(domain: "WaffleStore", code: -4, userInfo: [NSLocalizedDescriptionKey: "Direct installation rejected by iOS (missing entitlements or incompatible build)."])
            }
        }.value
    }
}

struct InstalledAppsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appData: AppData

    @State private var apps: [InstalledAppInfo] = []
    @State private var query: String = ""
    @State private var isLoading: Bool = true
    @State private var resolvingBundleID: String? = nil

    private var filteredApps: [InstalledAppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.bundleID.localizedCaseInsensitiveContains(q) ||
            $0.displayVersion.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter installed apps...", text: $query)
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

                if isLoading {
                    Spacer()
                    ProgressView("Loading installed apps...")
                    Spacer()
                } else if filteredApps.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(apps.isEmpty ? "No installed user apps visible (sandboxed or none installed)." : "No matching apps.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Spacer()
                } else {
                    List(filteredApps) { app in
                        Button {
                            selectApp(app)
                        } label: {
                            HStack(spacing: 12) {
                                if let icon = app.icon {
                                    Image(uiImage: icon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(10)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 44, height: 44)
                                        .foregroundColor(.secondary)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(app.bundleID)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text("Installed: v\(app.displayVersion)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.blue)
                                }

                                Spacer()

                                if resolvingBundleID == app.bundleID {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(resolvingBundleID != nil)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Installed Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reloadApps) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel".localized) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                reloadApps()
            }
        }
    }

    private func reloadApps() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loaded = InstalledAppsManager.fetchInstalledApps()
            await MainActor.run {
                self.apps = loaded
                self.isLoading = false
            }
        }
    }

    private func selectApp(_ app: InstalledAppInfo) {
        resolvingBundleID = app.bundleID
        Task {
            do {
                let url = try await InstalledAppsManager.lookupAppStoreURL(forBundleID: app.bundleID)
                await MainActor.run {
                    self.resolvingBundleID = nil
                    appData.appLink = url
                    dismiss()
                    if let ipaTool = appData.ipaTool {
                        let appID = extractAppId(from: url)
                        if !appID.isEmpty {
                            appData.isDowngrading = true
                            appData.hasAppBeenServed = false
                            downgradeApp(appId: appID, ipaTool: ipaTool)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.resolvingBundleID = nil
                    Alertinator.shared.alert(title: "Lookup failed", body: error.localizedDescription)
                }
            }
        }
    }
}
