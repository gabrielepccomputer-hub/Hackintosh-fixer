import Foundation

enum PrivilegedOperations {
    static func run(_ command: String) throws {
        let script = """
        on run argv
            do shell script (item 1 of argv) with administrator privileges
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let details = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw AuthorizationError.failed(details.isEmpty ? "Autorizzazione annullata o operazione non riuscita." : details)
            }
        } catch let error as AuthorizationError {
            throw error
        } catch {
            throw AuthorizationError.failed(error.localizedDescription)
        }
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private struct AuthorizationError: LocalizedError {
        let message: String

        init(failed message: String) {
            self.message = message
        }

        var errorDescription: String? {
            "Operazione amministratore non completata: \(message)"
        }
    }
}
