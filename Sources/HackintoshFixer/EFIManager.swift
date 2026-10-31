import Foundation

struct EFIManager {
    let configurationURL: URL

    init(efiRoot: URL) throws {
        let root = efiRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent("EFI/OC/config.plist")
        let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: candidate.path),
              values?.isSymbolicLink != true,
              resolvedCandidate.hasPrefix(root.path + "/") else {
            throw EFIError.configurationNotFound
        }
        configurationURL = candidate
    }

    func summary() throws -> String {
        let configuration = try readConfiguration()
        let entries = kernelEntries(from: configuration.root)
        guard !entries.isEmpty else {
            return "config.plist trovato. Nessun elemento in Kernel → Add."
        }
        let lines = entries.map { entry in
            "\(entry.bundlePath): \(entry.enabled ? "attivo" : "disattivato")"
        }
        return "config.plist trovato. Kext configurati in Kernel → Add:\n" + lines.joined(separator: "\n")
    }

    func kextStates() throws -> [String: Bool] {
        let entries = kernelEntries(from: try readConfiguration().root)
        guard Set(entries.map(\.bundlePath)).count == entries.count else {
            throw EFIError.duplicateConfiguredKext
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.bundlePath, $0.enabled) })
    }

    func apply(_ changes: [ConfigChange]) throws -> URL {
        guard !changes.isEmpty else { throw EFIError.noChanges }
        guard Set(changes.map(\.bundlePath)).count == changes.count else {
            throw EFIError.duplicateChanges
        }
        let configuration = try readConfiguration()
        var root = configuration.root
        guard var kernel = root["Kernel"] as? [String: Any],
              var addEntries = kernel["Add"] as? [[String: Any]] else {
            throw EFIError.invalidConfiguration
        }
        for change in changes {
            let matchingIndexes = addEntries.indices.filter {
                addEntries[$0]["BundlePath"] as? String == change.bundlePath
            }
            guard matchingIndexes.count == 1, let index = matchingIndexes.first else {
                throw EFIError.unknownKext(change.bundlePath)
            }
            addEntries[index]["Enabled"] = change.enabled
        }
        kernel["Add"] = addEntries
        root["Kernel"] = kernel

        let data = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: configuration.format,
            options: 0
        )
        return try replaceConfiguration(with: data)
    }

    func install(_ items: [KextInstallItem]) throws -> URL {
        guard !items.isEmpty else { throw EFIError.noChanges }
        let bundleNames = items.map(\.prepared.bundleName)
        guard Set(bundleNames).count == bundleNames.count else {
            throw EFIError.duplicateChanges
        }
        let configuration = try readConfiguration()
        guard var kernel = configuration.root["Kernel"] as? [String: Any] else {
            throw EFIError.invalidConfiguration
        }
        var addEntries = kernel["Add"] as? [[String: Any]] ?? []
        let existingEnabled = Set(addEntries.compactMap { entry -> String? in
            guard entry["Enabled"] as? Bool == true else { return nil }
            return entry["BundlePath"] as? String
        })
        let installing = Set(bundleNames)

        for item in items {
            guard item.kext.bundleName == item.prepared.bundleName,
                  !item.prepared.bundleIdentifier.isEmpty,
                  !item.prepared.version.isEmpty else {
                throw EFIError.invalidConfiguration
            }
            for required in item.kext.requiredKexts {
                guard existingEnabled.contains(required) || installing.contains(required) else {
                    throw EFIError.missingDependency(required)
                }
            }
            guard !addEntries.contains(where: { $0["BundlePath"] as? String == item.prepared.bundleName }) else {
                throw EFIError.kextAlreadyConfigured(item.prepared.bundleName)
            }
            addEntries.append([
                "Arch": "Any",
                "BundlePath": item.prepared.bundleName,
                "Comment": "\(item.prepared.bundleIdentifier) · \(item.prepared.version)",
                "Enabled": true,
                "Executable": item.prepared.executable,
                "MaxKernel": "",
                "MinKernel": "",
                "PlistPath": "Contents/Info.plist"
            ])
        }

        kernel["Add"] = addEntries
        var root = configuration.root
        root["Kernel"] = kernel
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: configuration.format,
            options: 0
        )
        let temp = try temporaryPlist(with: plistData)
        defer { try? FileManager.default.removeItem(at: temp.directory) }

        let kextsDirectory = configurationURL
            .deletingLastPathComponent()
            .appendingPathComponent("Kexts", isDirectory: true)
        if FileManager.default.fileExists(atPath: kextsDirectory.path) {
            let values = try kextsDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
            let resolvedOC = configurationURL.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let resolvedKexts = kextsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            guard values.isSymbolicLink != true, resolvedKexts.hasPrefix(resolvedOC) else {
                throw EFIError.unsafeKextDirectory
            }
        }
        let destinations = items.map {
            kextsDirectory.appendingPathComponent($0.prepared.bundleName, isDirectory: true)
        }
        for destination in destinations where FileManager.default.fileExists(atPath: destination.path) {
            throw EFIError.kextAlreadyPresent(destination.lastPathComponent)
        }
        let backup = Self.backupURL(for: configurationURL)
        let destinationPaths = destinations.map { PrivilegedOperations.quote($0.path) }
        let preflight = destinations.map {
            let path = PrivilegedOperations.quote($0.path)
            return "test ! -e \(path) && test ! -L \(path)"
        }
        let cleanup = destinationPaths.map { "/bin/rm -rf \($0) || true" }.joined(separator: "; ")
        let rollback = """
        rollback() { result=$?; trap - EXIT; if [ "$result" -ne 0 ]; then \(cleanup); /usr/bin/ditto \(PrivilegedOperations.quote(backup.path)) \(PrivilegedOperations.quote(configurationURL.path)) || true; fi; exit "$result"; }
        """
        let copies = items.map { item in
            "/usr/bin/ditto \(PrivilegedOperations.quote(item.prepared.sourceURL.path)) \(PrivilegedOperations.quote(kextsDirectory.appendingPathComponent(item.prepared.bundleName).path))"
        }
        let command = (
            ["set -e"] + preflight
                + ["/bin/mkdir -p \(PrivilegedOperations.quote(kextsDirectory.path))",
                   "/usr/bin/ditto \(PrivilegedOperations.quote(configurationURL.path)) \(PrivilegedOperations.quote(backup.path))",
                   rollback,
                   "trap rollback EXIT"]
                + copies
                + ["/usr/bin/ditto \(PrivilegedOperations.quote(temp.file.path)) \(PrivilegedOperations.quote(configurationURL.path))",
                   "trap - EXIT"]
        ).joined(separator: "; ")
        try PrivilegedOperations.run(command)
        return backup
    }

    private func replaceConfiguration(with data: Data) throws -> URL {
        let temp = try temporaryPlist(with: data)
        defer { try? FileManager.default.removeItem(at: temp.directory) }
        let backup = Self.backupURL(for: configurationURL)
        let command = [
            "/usr/bin/ditto \(PrivilegedOperations.quote(configurationURL.path)) \(PrivilegedOperations.quote(backup.path))",
            "/usr/bin/ditto \(PrivilegedOperations.quote(temp.file.path)) \(PrivilegedOperations.quote(configurationURL.path))"
        ].joined(separator: " && ")
        try PrivilegedOperations.run(command)
        return backup
    }

    private func temporaryPlist(with data: Data) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HackintoshFixer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("config.plist")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return (directory, file)
    }

    private func readConfiguration() throws -> (root: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        let data = try Data(contentsOf: configurationURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              root["Kernel"] is [String: Any] else {
            throw EFIError.invalidConfiguration
        }
        return (root, format)
    }

    private func kernelEntries(from root: [String: Any]) -> [(bundlePath: String, enabled: Bool)] {
        guard let kernel = root["Kernel"] as? [String: Any],
              let add = kernel["Add"] as? [[String: Any]] else { return [] }
        return add.compactMap { entry in
            guard let path = entry["BundlePath"] as? String,
                  let enabled = entry["Enabled"] as? Bool else { return nil }
            return (path, enabled)
        }
    }

    private static func backupURL(for configurationURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let token = UUID().uuidString.prefix(8)
        let baseName = configurationURL.lastPathComponent + ".backup-\(formatter.string(from: Date()))-\(token)"
        var candidate = configurationURL.deletingLastPathComponent().appendingPathComponent(baseName)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = configurationURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private enum EFIError: LocalizedError {
        case configurationNotFound
        case invalidConfiguration
        case noChanges
        case duplicateChanges
        case duplicateConfiguredKext
        case unknownKext(String)
        case missingDependency(String)
        case kextAlreadyConfigured(String)
        case kextAlreadyPresent(String)
        case unsafeKextDirectory

        var errorDescription: String? {
            switch self {
            case .configurationNotFound:
                "Seleziona il volume EFI montato che contiene EFI/OC/config.plist."
            case .invalidConfiguration:
                "config.plist non è valido o non contiene la sezione OpenCore Kernel."
            case .noChanges:
                "Seleziona almeno una modifica prima di applicarla."
            case .duplicateChanges:
                "La risposta contiene modifiche duplicate. Nessuna modifica applicata."
            case .duplicateConfiguredKext:
                "config.plist contiene voci kext duplicate. Correggile prima di installare nuovi kext."
            case .unknownKext(let name):
                "Il kext '\(name)' non è presente una sola volta in Kernel → Add. Nessuna modifica applicata."
            case .missingDependency(let name):
                "Installa e abilita prima il kext richiesto \(name)."
            case .kextAlreadyConfigured(let name):
                "\(name) è già configurato in OpenCore. Nessun file è stato sostituito."
            case .kextAlreadyPresent(let name):
                "\(name) esiste già nella cartella Kexts. Nessun file è stato sostituito."
            case .unsafeKextDirectory:
                "La cartella EFI/OC/Kexts è un collegamento o punta fuori da OpenCore. Installazione bloccata."
            }
        }
    }
}
