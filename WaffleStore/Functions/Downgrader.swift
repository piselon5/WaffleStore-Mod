import Foundation
import SwiftUI
import UIKit
import PartyUI
import MapleSAP

enum IPAHandlingError: LocalizedError {
    case encryptedIPA

    var errorDescription: String? {
        switch self {
        case .encryptedIPA:
            return "The downloaded IPA is FairPlay-encrypted. Enable Risky Options to keep encrypted IPAs; signing alone will not decrypt or make it launch."
        }
    }
}

func fetchBilinVersionMap(appId: String) async -> [String: String] {
    guard let url = URL(string: "https://apis.bilin.eu.org/history/\(appId)") else { return [:] }
    var req = URLRequest(url: url)
    req.timeoutInterval = 6
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for item in list {
            let extId: String
            if let s = item["external_identifier"] as? String { extId = s }
            else if let n = item["external_identifier"] as? NSNumber { extId = n.stringValue }
            else { continue }
            if let ver = item["bundle_version"] as? String, !ver.isEmpty {
                map[extId] = ver
            }
        }
        return map
    } catch {
        return [:]
    }
}

func downgradeApp(appId: String, ipaTool: IPATool) {
    let appData = AppData.shared
    appData.applicationStatus = "Finding available versions…"
    Task { @MainActor in
        do {
            let app = try await ipaTool.lookup(appId)
            async let versionMapTask = fetchBilinVersionMap(appId: String(app.id))
            var latest: StoreDownload? = nil
            var descriptorError: Error? = nil
            do {
                latest = try await ipaTool.descriptor(app: app)
            } catch {
                descriptorError = error
            }
            let versionMap = await versionMapTask
            let descriptorVersions = latest?.availableVersionIDs ?? []
            let bilinVersions = versionMap.keys.sorted { (UInt64($0) ?? 0) > (UInt64($1) ?? 0) }
            let versions = Array(Set(descriptorVersions + bilinVersions)).sorted { (UInt64($0) ?? 0) > (UInt64($1) ?? 0) }
            guard !versions.isEmpty else {
                throw descriptorError ?? StoreError.unavailable
            }
            appData.isDowngrading = false

            let entries = versions.map { extID in
                VersionPickerEntry(externalVersionID: extID, bundleVersion: versionMap[extID])
            }
            let installedVer = InstalledAppsManager.installedVersion(for: app.bundleID)
            let mapleMsg = (descriptorError as? LocalizedError)?.errorDescription
            appData.versionPickerState = VersionPickerState(
                app: app,
                tool: ipaTool,
                entries: entries,
                installedVersion: installedVer,
                mapleErrorMessage: mapleMsg
            )
        } catch {
            resetDowngradeProgress()
            let errText = (error as? LocalizedError)?.errorDescription ?? "Store operation failed."
            Alertinator.shared.alert(title: "Failed to find app versions".localized, body: errText)
        }
    }
}
func cleanUp() {
    let fm = FileManager.default
    for name in ["app.ipa", "app"] {
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent(name))
    }
}
func resetDowngradeProgress() {
    let appData = AppData.shared
    appData.isDowngrading = false; appData.showsDowngradeProgress = false
}
extension AppData {
    func download(app: StoreApp, version: String, tool: IPATool, expectedVersion: String? = nil, installWhenReady: Bool = false) {
        guard storeTask == nil else { return }
        activeDownloadName = app.name
        isDowngrading = true; showsDowngradeProgress = true; downgradeProgress = 0
        storeError = ""
        downloadReady = nil; installationRequest = nil
        downgradeProgressDetail = "Preparing download…"

        storeTask = Task {
            defer { storeTask = nil; isDowngrading = false; showsDowngradeProgress = false }
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory.appendingPathComponent("store-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            do {
                try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                storeStage("Requesting selected externalVersionId")
                let descriptor = try await tool.descriptor(app: app, version: version)
                try Task.checkCancellation()
                storeStage("Downloading IPA from CDN")
                let source = scratch.appendingPathComponent("source.ipa")
                var received: URL?
                for attempt in 0..<3 {
                    do {
                        let downloader = CDNDownload(destination: source) { progress, written, expected in
                            Task { @MainActor in
                                guard self.isDowngrading, self.downgradeProgress < 0.85 else { return }
                                self.downgradeProgress = progress * 0.85
                                self.downgradeProgressDetail = expected > 0 ? "\(written / 1_048_576) / \(expected / 1_048_576) MiB" : "\(written / 1_048_576) MiB"
                            }
                        }
                        received = try await downloader.run(descriptor.url)
                        break
                    } catch {
                        try Task.checkCancellation()
                        let retryable: Bool
                        if let error = error as? URLError { retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) }
                        else if let error = error as? CDNHTTPFailure { retryable = [429, 500, 502, 503, 504].contains(error.status) }
                        else { retryable = false }
                        guard retryable, attempt < 2 else { throw error }
                        try? fm.removeItem(at: source)
                        storeStage("Retrying CDN download")
                        let delay = try StoreRetry.delay((error as? CDNHTTPFailure)?.retryAfter, attempt: attempt)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
                guard let source = received else { throw StoreError.packageInvalid }
                storeStage("Validating data")
                downgradeProgress = 0.85
                let staged = scratch.appendingPathComponent("prepared.ipa")
                let info = try await Task.detached(priority: .userInitiated) {
                    try NativePackage.prepare(source: source, destination: staged, app: app, descriptor: descriptor)
                }.value
                try Task.checkCancellation()
                let encryption = IPAEncryptionDetector.status(for: staged)
                switch encryption {
                case .encrypted:
                    print("[diagnostic] IPA is FairPlay-encrypted")
                    guard AppData.shared.allowEncryptedIPASigning else { throw IPAHandlingError.encryptedIPA }
                    storeStage("Encrypted IPA allowed for signing attempt")
                case .decrypted:
                    print("[diagnostic] IPA executable is not FairPlay-encrypted")
                case .unknown:
                    print("[diagnostic] IPA encryption state could not be determined")
                }
                if let expectedVersion, info.version != expectedVersion { throw StoreError.versionMismatch }
                let downloads = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("Downloads", isDirectory: true)
                try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
                let filename = "\(app.id)-\(descriptor.externalVersionID)-\(UUID().uuidString).ipa"
                let destination = downloads.appendingPathComponent(filename)
                let record = DownloadRecord(filename: filename, appID: app.id, appName: app.name, bundleID: info.bundleID,
                    version: info.version, build: info.build, externalVersionID: descriptor.externalVersionID, date: Date())
                let sidecar = destination.deletingPathExtension().appendingPathExtension("json")
                try JSONEncoder().encode(record).write(to: sidecar, options: .atomic)
                do { try fm.moveItem(at: staged, to: destination) }
                catch { try? fm.removeItem(at: sidecar); throw error }
                completedDownloads = DownloadRecord.load()
                downloadedIPAURL = destination; hasAppBeenServed = true
                appBundleID = info.bundleID; appVersion = info.version
                storeStage("Downgrade succesful! Ready to sign or export.")
                if installWhenReady { installationRequest = record }
                else { downloadReady = record }

                downgradeProgress = 1; applicationIcon = "checkmark.circle.fill"
            } catch {
                if error is CancellationError || Task.isCancelled {
                    applicationStatus = "Download cancelled."
                } else {
                    storeError = (error as? CDNHTTPFailure).map { "CDN request failed (HTTP \($0.status))." } ?? (error as? StoreError)?.localizedDescription ?? (error as? SAPError)?.localizedDescription ?? "Store operation failed (code \((error as NSError).code))."
                    applicationStatus = "Download failed."; applicationIcon = "xmark.circle.fill"
                    Alertinator.shared.alert(title: "Download failed", body: storeError)
                }
            }
        }
    }
    private func storeStage(_ stage: String) {
        applicationStatus = stage; downgradeProgressDetail = stage

        print("Apple Store stage: \(stage)")
    }
    func deleteDownload(_ record: DownloadRecord) throws {
        try record.deleteFiles()
        if downloadReady?.id == record.id { downloadReady = nil }
        restoreDownloadedIPA()
    }
    func deleteAllDownloads() throws {
        guard !isDowngrading else { return }
        defer { restoreDownloadedIPA() }
        try DownloadRecord.deleteAllFiles()
        downloadReady = nil
    }
    func restoreDownloadedIPA() {
        completedDownloads = DownloadRecord.load()
        downloadedIPAURL = nil; hasAppBeenServed = false
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let files = try? fm.contentsOfDirectory(at: docs.appendingPathComponent("Downloads"),
                  includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        downloadedIPAURL = files.filter { $0.pathExtension == "ipa" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.first
        hasAppBeenServed = downloadedIPAURL != nil
        if let record = completedDownloads.first { appBundleID = record.bundleID; appVersion = record.version }
        else { appBundleID = ""; appVersion = "" }
    }
}
