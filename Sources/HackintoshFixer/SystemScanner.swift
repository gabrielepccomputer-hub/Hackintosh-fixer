import Foundation

enum SystemScanner {
    static func scan() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = [
            "-json",
            "-detailLevel", "mini",
            "SPHardwareDataType",
            "SPPCIDataType",
            "SPUSBDataType",
            "SPDisplaysDataType",
            "SPStorageDataType"
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ScanError.failed("system_profiler si è chiuso con codice \(process.terminationStatus).")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        let redacted = redactPrivateIdentifiers(in: object)
        let safeData = try JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys])
        guard let report = String(data: safeData, encoding: .utf8) else {
            throw ScanError.invalidOutput
        }
        return report
    }

    private static func redactPrivateIdentifiers(in value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                let key = item.key.lowercased()
                guard !key.contains("serial"), !key.contains("uuid"), !key.contains("udid") else { return }
                result[item.key] = redactPrivateIdentifiers(in: item.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redactPrivateIdentifiers(in:))
        }
        return value
    }

    private enum ScanError: LocalizedError {
        case failed(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .failed(let reason): reason
            case .invalidOutput: "Il rapporto hardware non è in un formato leggibile."
            }
        }
    }
}
