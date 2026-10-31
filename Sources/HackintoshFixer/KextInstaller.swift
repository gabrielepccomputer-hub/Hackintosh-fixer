import Foundation

struct SupportedKext: Identifiable, Hashable, Sendable {
    let repository: String
    let bundleName: String
    let displayName: String
    let description: String
    let requiredKexts: [String]

    var id: String { repository }
    var releaseURL: URL { URL(string: "https://github.com/\(repository)/releases")! }

    static let catalog: [SupportedKext] = [
        .init(
            repository: "acidanthera/Lilu",
            bundleName: "Lilu.kext",
            displayName: "Lilu",
            description: "Framework di patch usato da diversi kext.",
            requiredKexts: []
        ),
        .init(
            repository: "acidanthera/VirtualSMC",
            bundleName: "VirtualSMC.kext",
            displayName: "VirtualSMC",
            description: "Emulazione SMC per sistemi Intel compatibili.",
            requiredKexts: []
        ),
        .init(
            repository: "acidanthera/WhateverGreen",
            bundleName: "WhateverGreen.kext",
            displayName: "WhateverGreen",
            description: "Supporto e patch grafica per hardware compatibile.",
            requiredKexts: ["Lilu.kext"]
        ),
        .init(
            repository: "acidanthera/AppleALC",
            bundleName: "AppleALC.kext",
            displayName: "AppleALC",
            description: "Audio AppleHDA per codec supportati.",
            requiredKexts: ["Lilu.kext"]
        ),
        .init(
            repository: "acidanthera/IntelMausi",
            bundleName: "IntelMausi.kext",
            displayName: "IntelMausi",
            description: "Ethernet Intel supportata dal progetto.",
            requiredKexts: []
        )
    ]
}

struct PreparedKext: Sendable {
    let sourceURL: URL
    let stagingDirectory: URL
    let bundleName: String
    let bundleIdentifier: String
    let version: String
    let executable: String

    func removeStagingDirectory() throws {
        try FileManager.default.removeItem(at: stagingDirectory)
    }
}

struct KextInstallItem: Sendable {
    let kext: SupportedKext
    let prepared: PreparedKext
}

enum KextReleaseService {
    private struct Release: Decodable {
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    static func prepare(_ kext: SupportedKext) async throws -> PreparedKext {
        let releaseURL = URL(string: "https://api.github.com/repos/\(kext.repository)/releases/latest")!
        var request = URLRequest(url: releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HackintoshFixer/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (releaseData, releaseResponse) = try await URLSession.shared.data(for: request)
        guard let releaseHTTP = releaseResponse as? HTTPURLResponse,
              (200..<300).contains(releaseHTTP.statusCode),
              releaseData.count <= 10_000_000 else {
            throw InstallerError.githubResponse
        }
        let release = try JSONDecoder().decode(Release.self, from: releaseData)
        guard let asset = release.assets.first(where: {
                  $0.name.lowercased().contains("-release.zip")
              }),
              asset.browserDownloadURL.host == "github.com",
              asset.browserDownloadURL.path.hasPrefix("/\(kext.repository)/releases/download/") else {
            throw InstallerError.releaseAssetNotFound(kext.displayName)
        }

        var downloadRequest = URLRequest(url: asset.browserDownloadURL)
        downloadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        downloadRequest.setValue("HackintoshFixer/1.0", forHTTPHeaderField: "User-Agent")
        downloadRequest.timeoutInterval = 90
        let (archiveData, response) = try await URLSession.shared.data(for: downloadRequest)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
                  .contains(http.url?.host ?? ""),
              archiveData.count <= 250_000_000 else {
            throw InstallerError.downloadFailed(kext.displayName)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("HackintoshFixer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let archive = staging.appendingPathComponent("release.zip")
            let extraction = staging.appendingPathComponent("extracted", isDirectory: true)
            try archiveData.write(to: archive, options: .atomic)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            try extract(archive, to: extraction)
            let bundle = try findBundle(named: kext.bundleName, under: extraction)
            let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
            let infoData = try Data(contentsOf: infoURL)
            guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
                  let identifier = info["CFBundleIdentifier"] as? String,
                  !identifier.isEmpty,
                  let version = info["CFBundleVersion"] as? String,
                  !version.isEmpty else {
                throw InstallerError.invalidBundle(kext.bundleName)
            }
            let executableName = info["CFBundleExecutable"] as? String ?? ""
            guard !executableName.contains("/"),
                  !executableName.contains("\\"),
                  !executableName.contains("..") else {
                throw InstallerError.invalidBundle(kext.bundleName)
            }
            if !executableName.isEmpty,
               !FileManager.default.fileExists(
                   atPath: bundle.appendingPathComponent("Contents/MacOS/\(executableName)").path
               ) {
                throw InstallerError.invalidBundle(kext.bundleName)
            }
            return PreparedKext(
                sourceURL: bundle,
                stagingDirectory: staging,
                bundleName: kext.bundleName,
                bundleIdentifier: identifier,
                version: version,
                executable: executableName.isEmpty ? "" : "Contents/MacOS/\(executableName)"
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func extract(_ archive: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallerError.archiveExtractionFailed(details)
        }
    }

    private static func findBundle(named name: String, under root: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw InstallerError.bundleNotFound(name)
        }
        for case let candidate as URL in enumerator where candidate.lastPathComponent == name {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let info = candidate.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: info.path) else { continue }
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedCandidate.hasPrefix(resolvedRoot) else { continue }
            return candidate
        }
        throw InstallerError.bundleNotFound(name)
    }

    private enum InstallerError: LocalizedError {
        case githubResponse
        case releaseAssetNotFound(String)
        case downloadFailed(String)
        case archiveExtractionFailed(String)
        case bundleNotFound(String)
        case invalidBundle(String)

        var errorDescription: String? {
            switch self {
            case .githubResponse:
                "GitHub non ha restituito una release valida. Riprova più tardi."
            case .releaseAssetNotFound(let name):
                "Non è stato trovato un archivio ZIP ufficiale per \(name)."
            case .downloadFailed(let name):
                "Download di \(name) non riuscito o archivio troppo grande."
            case .archiveExtractionFailed(let details):
                "Estrazione dell'archivio non riuscita: \(details)"
            case .bundleNotFound(let name):
                "L'archivio ufficiale non contiene \(name)."
            case .invalidBundle(let name):
                "Il bundle \(name) non contiene metadati validi."
            }
        }
    }
}
