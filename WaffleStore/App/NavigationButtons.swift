//
//  NavigationButtons.swift
//  WaffleStore
//
//  Created by lunginspector on 2/24/26.
//

import SwiftUI
import PartyUI
import UIKit

struct NavigationButtons: View {
    @EnvironmentObject var appData: AppData
    @StateObject private var installer = OTAInstaller()

    private var primaryActionTitle: String {
        guard let record = appData.downloadReady else { return "Downgrade App".localized }
        if appData.signingCertificate != nil && !record.filename.hasPrefix("Signed-") {
            return "Sign & Install"
        }
        return "Install App"
    }

    private var primaryActionIcon: String {
        guard let record = appData.downloadReady else { return "square.and.arrow.down" }
        if appData.signingCertificate != nil && !record.filename.hasPrefix("Signed-") {
            return "signature"
        }
        return "arrow.down.app"
    }
    
    var body: some View {
        VStack {
            if !appData.isAuthenticated {
                Button(action: {
                    Haptic.shared.play(.soft)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if appData.appleId.isEmpty || appData.password.isEmpty {
                            Alertinator.shared.alert(title: "No Apple ID details were input!".localized, body: "Login prompt description".localized)
                        } else {
                            appData.startAppleLogin()
                        }
                    }
                }) {
                    if appData.hasSent2FACode {
                        ButtonLabel(text: "Log In".localized, icon: "arrow.right")
                    } else {
                        ButtonLabel(text: "Send 2FA Code".localized, icon: "key")
                    }
                }
                .buttonStyle(FancyButtonStyle())
                .disabled(appData.appleId.isEmpty || appData.password.isEmpty)
                .disabled(appData.hasSent2FACode ? appData.code.isEmpty : false)
            } else {
                if appData.isDowngrading {
                    Button(action: {
                        Haptic.shared.play(.soft)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
#if canImport(UIKit)
    if let url = URL(string: "wafflestore://open") {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    } else if let appStoreURL = URL(string: "itms-apps://itunes.apple.com/app/id") {
        UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
    }
#endif
                        }
                    }) {
                        ButtonLabel(text: "Open App".localized, icon: "arrow.up.forward.app")
                    }
                    .buttonStyle(FancyButtonStyle(color: .blue))
                    .disabled(!appData.hasAppBeenServed)
                    
                    Button(action: {
                        Haptic.shared.play(.heavy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            exitinator()
                        }
                    }) {
                        ButtonLabel(text: "Go to Home Screen".localized, icon: "house")
                    }
                    .buttonStyle(FancyButtonStyle())
                    .disabled(!appData.hasAppBeenServed)
                } else {
                    Button(action: runPrimaryAction) {
                        ButtonLabel(text: primaryActionTitle, icon: primaryActionIcon)
                    }
                    .buttonStyle(FancyButtonStyle())
                    .disabled(appData.downloadReady == nil && appData.appLink.isEmpty)

                    if let readyRecord = appData.downloadReady, let fileURL = readyRecord.fileURL {
                        Button(action: {
                            Haptic.shared.play(.soft)
                            presentShareSheet(with: fileURL)
                        }) {
                            ButtonLabel(text: "Export / Open in Filza", icon: "square.and.arrow.up")
                        }
                        .buttonStyle(FancyButtonStyle(color: .orange))
                    }
                    
                    let currentAppId = extractAppId(from: appData.appLink)
                    let existingFav = appData.favourites.first { extractAppId(from: $0.appLink) == currentAppId }
                    let isFavourited = existingFav != nil

                    Button(action: {
                        Haptic.shared.play(.soft)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if appData.appLink.isEmpty {
                                Alertinator.shared.alert(title: "Cannot Add to Favourites".localized, body: "Please enter an app link first.".localized)
                                return
                            }
                            
                            if isFavourited {
                                if let fav = existingFav {
                                    appData.favourites = FavouritesStore.remove(fav)
                                    Haptic.shared.play(.soft)
                                    Alertinator.shared.alert(title: "Removed from Favourites".localized, body: "This app has been removed from your favourites.".localized)
                                }
                            } else {
                                let currentLink = appData.appLink
                                fetchAppNameAndBundleId(forLink: currentLink) { trackName, bundleId in
                                    DispatchQueue.main.async {
                                        let resolvedName = trackName.isEmpty ? (bundleId.isEmpty ? "App Store Link" : bundleId) : trackName
                                        let resolvedBundle = bundleId.isEmpty ? appData.appBundleID : bundleId
                                        let favourite = FavouriteApp(
                                            appLink: currentLink,
                                            bundleId: resolvedBundle,
                                            appName: resolvedName
                                        )
                                        appData.favourites = FavouritesStore.add(favourite)
                                        Haptic.shared.play(.soft)
                                        Alertinator.shared.alert(title: "Added to Favourites".localized, body: "This app has been added to your favourites for quick access.".localized)
                                    }
                                }
                            }
                        }
                    }) {
                        ButtonLabel(text: isFavourited ? "Remove from Favourites".localized : "Add to Favourites".localized, icon: isFavourited ? "star.fill" : "star")
                    }
                    .buttonStyle(FancyButtonStyle(color: .mint))
                    .disabled(appData.appLink.isEmpty)
                    

                }
            }
        }
        .onChange(of: appData.installationRequest?.id) { _ in
            if let req = appData.installationRequest {
                appData.installationRequest = nil
                appData.downloadReady = req
                handleDownload(req)
            }
        }
    }

    private func runPrimaryAction() {
        Haptic.shared.play(.soft)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let record = appData.downloadReady {
                handleDownload(record)
            } else {
                startDowngrade()
            }
        }
    }

    private func presentDirectAlert(title: String, message: String, shareURL: URL? = nil) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let root = windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windows.first?.rootViewController else {
            return
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let shareURL {
            alert.addAction(UIAlertAction(title: "Export / Share IPA", style: .default) { _ in
                presentShareSheet(with: shareURL)
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top.present(alert, animated: true)
    }

    private func handleDownload(_ record: DownloadRecord) {
        if appData.signingCertificate != nil && !record.filename.hasPrefix("Signed-") {
            appData.signDownloadedIPA(record)
            return
        }
        guard let fileURL = record.fileURL else {
            presentDirectAlert(title: "Error", message: "Downloaded IPA file not found.")
            return
        }
        appData.applicationStatus = "Installing \(record.appName)..."
        Task {
            do {
                try await InstalledAppsManager.installIPA(at: fileURL, bundleID: record.bundleID)
                await MainActor.run {
                    appData.applicationStatus = "Installed \(record.appName)!"
                    appData.hasAppBeenServed = true
                    presentDirectAlert(title: "Installed", message: "\(record.appName) (\(record.version)) was installed on your device.")
                }
            } catch {
                await MainActor.run {
                    appData.applicationStatus = "Direct install failed: \(error.localizedDescription)"
                    presentDirectAlert(
                        title: "Direct Install Failed",
                        message: "\(error.localizedDescription)\n\nNote: FairPlay-encrypted IPAs cannot be installed by TrollStore (Error 180) and require TrollStore entitlements on WaffleStore (install .tipa via TrollStore) or using App Store + AppStoreTrollerExact tweak.",
                        shareURL: fileURL
                    )
                }
            }
        }
    }

    private func handleTrollStoreInstall(_ record: DownloadRecord) {
        do {
            try installer.start(record)
            if let tsURL = installer.trollStoreURL, UIApplication.shared.canOpenURL(tsURL) {
                UIApplication.shared.open(tsURL)
            } else if let pageURL = installer.pageURL {
                UIApplication.shared.open(pageURL)
            }
        } catch {
            Alertinator.shared.alert(title: "TrollStore install failed", body: error.localizedDescription)
        }
    }

    private func startDowngrade() {
        guard !appData.appLink.isEmpty, let ipaTool = appData.ipaTool else { return }
        let appID = extractAppId(from: appData.appLink)
        guard !appID.isEmpty else { return }
        print("App ID: \(appID)")
        appData.isDowngrading = true
        appData.hasAppBeenServed = false
        downgradeApp(appId: appID, ipaTool: ipaTool)
    }
}

func extractAppId(from link: String) -> String {
    var parsed = link.components(separatedBy: "id").last ?? ""
    for char in parsed {
        if !char.isNumber {
            if let index = parsed.firstIndex(of: char) {
                parsed = String(parsed.prefix(upTo: index))
            }
            break
        }
    }
    return parsed
}

func fetchAppNameAndBundleId(forLink: String, completion: @escaping (String, String) -> Void) {
    let parsedAppId = extractAppId(from: forLink)
    guard !parsedAppId.isEmpty, let url = URL(string: "https://itunes.apple.com/lookup?id=\(parsedAppId)") else {
        completion("", "")
        return
    }
    
    URLSession.shared.dataTask(with: url) { data, response, error in
        guard let data = data, error == nil else {
            completion("", "")
            return
        }
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let firstResult = results.first {
                let trackName = firstResult["trackName"] as? String ?? ""
                let bundleId = firstResult["bundleId"] as? String ?? ""
                completion(trackName, bundleId)
            } else {
                completion("", "")
            }
        } catch {
            completion("", "")
        }
    }.resume()
}
