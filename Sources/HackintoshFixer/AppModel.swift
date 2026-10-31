import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var language: AppLanguage
    @Published var provider: AIProvider
    @Published var modelName: String
    @Published var apiKey: String
    @Published var computerModel: String
    @Published var motherboardModel: String
    @Published var macOSVersion: String
    @Published var otherHardwareInfo: String
    @Published var onboardingStep = 0
    @Published var hasCompletedOnboarding: Bool
    @Published var hardwareReport = ""
    @Published var efiSummary = ""
    @Published var selectedEFI: URL?
    @Published var analysis: AIAnalysis?
    @Published var selectedChanges = Set<String>()
    @Published var selectedKextRecommendations = Set<String>()
    @Published var preparedRecommendedKexts: [String: PreparedKext] = [:]
    @Published var recommendedKextPlanIDs: [String] = []
    @Published var selectedKextID = SupportedKext.catalog[0].id
    @Published var preparedKext: PreparedKext?
    @Published var preparedKextID: String?
    @Published var chatMessages: [ChatMessage] = []
    @Published var chatInput = ""
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        let storedLanguage = defaults.string(forKey: "app.language") ?? AppLanguage.english.rawValue
        language = AppLanguage(rawValue: storedLanguage) ?? .english
        let storedProvider = defaults.string(forKey: "ai.provider") ?? AIProvider.gemini.rawValue
        provider = AIProvider(rawValue: storedProvider) ?? .gemini
        let savedModel = defaults.string(forKey: "ai.model")
        modelName = savedModel.flatMap { provider.availableModels.contains($0) ? $0 : nil } ?? provider.defaultModel
        apiKey = KeychainStore.read(account: provider.keychainAccount)
        computerModel = defaults.string(forKey: "pc.computerModel") ?? ""
        motherboardModel = defaults.string(forKey: "pc.motherboardModel") ?? ""
        macOSVersion = defaults.string(forKey: "pc.macOSVersion") ?? ""
        otherHardwareInfo = defaults.string(forKey: "pc.otherHardwareInfo") ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "setup.completed")
        if hasCompletedOnboarding {
            chatMessages = [
                ChatMessage(
                    role: .assistant,
                    text: AppStrings.text("chat.welcome", language: language)
                )
            ]
        }
    }

    var localizedProfile: String {
        let labels = language == .italian
            ? ("Build PC", "Scheda madre", "Versione macOS", "Altri componenti/dettagli")
            : ("PC/build", "Motherboard", "macOS version", "Other hardware/details")
        return [
            "\(labels.0): \(computerModel)",
            "\(labels.1): \(motherboardModel)",
            "\(labels.2): \(macOSVersion)",
            "\(labels.3): \(otherHardwareInfo)"
        ].joined(separator: "\n")
    }

    var selectedKext: SupportedKext {
        SupportedKext.catalog.first(where: { $0.id == selectedKextID }) ?? SupportedKext.catalog[0]
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: "app.language")
        if !hasCompletedOnboarding && onboardingStep == 0 {
            return
        }
    }

    func changeProvider(_ provider: AIProvider) {
        self.provider = provider
        let savedModel = defaults.string(forKey: "ai.model.\(provider.keychainAccount)")
        modelName = savedModel.flatMap { provider.availableModels.contains($0) ? $0 : nil } ?? provider.defaultModel
        apiKey = KeychainStore.read(account: provider.keychainAccount)
    }

    func saveDeviceProfile() -> Bool {
        guard !computerModel.trimmed.isEmpty || !motherboardModel.trimmed.isEmpty,
              !macOSVersion.trimmed.isEmpty else {
            errorMessage = AppStrings.text("settings.profile_required", language: language)
            return false
        }
        persistProfile()
        onboardingStep = 1
        return true
    }

    func completeOnboarding() {
        guard saveSettings() else { return }
        hasCompletedOnboarding = true
        defaults.set(true, forKey: "setup.completed")
        chatMessages = [
            ChatMessage(
                role: .assistant,
                text: AppStrings.text("chat.welcome", language: language)
            )
        ]
    }

    @discardableResult
    func saveSettings() -> Bool {
        guard !computerModel.trimmed.isEmpty || !motherboardModel.trimmed.isEmpty,
              !macOSVersion.trimmed.isEmpty else {
            errorMessage = AppStrings.text("settings.profile_required", language: language)
            return false
        }
        guard !apiKey.trimmed.isEmpty, !modelName.trimmed.isEmpty else {
            errorMessage = AppStrings.text("api.required", language: language)
            return false
        }
        do {
            try KeychainStore.save(apiKey.trimmed, account: provider.keychainAccount)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        persistProfile()
        defaults.set(provider.rawValue, forKey: "ai.provider")
        defaults.set(modelName, forKey: "ai.model")
        defaults.set(modelName, forKey: "ai.model.\(provider.keychainAccount)")
        statusMessage = AppStrings.text("settings.saved", language: language)
        return true
    }

    func scanHardware() {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = AppStrings.text("chat.working.scan", language: language)
        Task {
            do {
                hardwareReport = try await Task.detached(priority: .userInitiated) {
                    try SystemScanner.scan()
                }.value
                statusMessage = AppStrings.text("scan.complete", language: language)
                chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))
            } catch {
                let message = AppStrings.text("scan.failed", language: language) + error.localizedDescription
                errorMessage = message
                chatMessages.append(ChatMessage(role: .assistant, text: message))
            }
            isWorking = false
        }
    }

    func chooseEFI() {
        let panel = NSOpenPanel()
        panel.title = language == .italian ? "Seleziona il volume EFI montato" : "Choose the mounted EFI volume"
        panel.message = AppStrings.text("efi.empty", language: language)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let manager = try EFIManager(efiRoot: url)
            selectedEFI = url
            efiSummary = try manager.summary()
            statusMessage = AppStrings.text("efi.selected", language: language) + url.lastPathComponent
            analysis = nil
            selectedChanges.removeAll()
            preparedRecommendedKexts.values.forEach { try? $0.removeStagingDirectory() }
            preparedRecommendedKexts.removeAll()
            recommendedKextPlanIDs = []
            chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendChatMessage() {
        let requestText = chatInput.trimmed
        guard !requestText.isEmpty, !isWorking else { return }
        chatMessages.append(ChatMessage(role: .user, text: requestText))
        chatInput = ""
        analysis = nil
        selectedChanges.removeAll()
        preparedRecommendedKexts.values.forEach { try? $0.removeStagingDirectory() }
        preparedRecommendedKexts.removeAll()
        recommendedKextPlanIDs = []
        isWorking = true
        statusMessage = AppStrings.text("chat.working.scan", language: language)
        chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))

        Task {
            do {
                if hardwareReport.isEmpty {
                    hardwareReport = try await Task.detached(priority: .userInitiated) {
                        try SystemScanner.scan()
                    }.value
                    statusMessage = AppStrings.text("scan.complete", language: language)
                    chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))
                }

                if let selectedEFI {
                    efiSummary = try EFIManager(efiRoot: selectedEFI).summary()
                } else {
                    efiSummary = AppStrings.text("chat.no_efi", language: language)
                }

                guard !apiKey.trimmed.isEmpty, !modelName.trimmed.isEmpty else {
                    throw ChatError.aiSettingsRequired
                }
                try KeychainStore.save(apiKey.trimmed, account: provider.keychainAccount)
                statusMessage = AppStrings.text("chat.working.ai", language: language)
                chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))
                let result = try await AIService.analyze(
                    provider: provider,
                    model: modelName,
                    apiKey: apiKey.trimmed,
                    hardwareReport: hardwareReport,
                    efiSummary: efiSummary,
                    profile: localizedProfile,
                    conversation: chatMessages,
                    language: language
                )
                analysis = result
                selectedChanges = Set(result.configChanges.map(\.bundlePath))
                selectedKextRecommendations = Set(result.kextRecommendations.map(\.repository))
                let assistantResponse = [result.summary] +
                    result.recommendations.map { "• \($0.title): \($0.reason)" } +
                    result.kextRecommendations.compactMap { recommendation in
                        SupportedKext.catalog.first(where: { $0.repository == recommendation.repository }).map {
                            "• \($0.displayName): \(recommendation.reason)"
                        }
                    }
                chatMessages.append(ChatMessage(role: .assistant, text: assistantResponse.joined(separator: "\n\n")))
                statusMessage = AppStrings.text("chat.working.done", language: language)
            } catch {
                let details = error is ChatError
                    ? AppStrings.text("api.required", language: language)
                    : error.localizedDescription
                let message = AppStrings.text("chat.error", language: language) + details
                errorMessage = message
                chatMessages.append(ChatMessage(role: .assistant, text: message))
            }
            isWorking = false
        }
    }

    func applySelectedChanges() {
        guard let selectedEFI, let analysis else { return }
        let changes = analysis.configChanges.filter { selectedChanges.contains($0.bundlePath) }
        guard !changes.isEmpty else {
            errorMessage = language == .italian ? "Seleziona almeno una modifica." : "Select at least one change."
            return
        }
        runEFIAction(status: AppStrings.text("work.installing", language: language)) {
            let backup = try EFIManager(efiRoot: selectedEFI).apply(changes)
            return (backup, try EFIManager(efiRoot: selectedEFI).summary())
        }
    }

    func downloadSelectedKext() {
        let kext = selectedKext
        isWorking = true
        statusMessage = AppStrings.text("work.download", language: language) + " \(kext.displayName)…"
        Task {
            do {
                if let preparedKext { try preparedKext.removeStagingDirectory() }
                preparedKext = try await KextReleaseService.prepare(kext)
                preparedKextID = kext.id
                statusMessage = "\(kext.displayName) \(preparedKext?.version ?? "")"
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func installDownloadedKext() {
        guard let selectedEFI, let preparedKext,
              let kext = SupportedKext.catalog.first(where: { $0.id == preparedKextID }) else {
            errorMessage = language == .italian ? "Seleziona EFI e scarica prima un kext." : "Choose an EFI and download a kext first."
            return
        }
        installKextItems([KextInstallItem(kext: kext, prepared: preparedKext)], efi: selectedEFI)
    }

    func downloadRecommendedKexts() {
        guard let analysis, let selectedEFI else {
            errorMessage = language == .italian
                ? "Analizza l'hardware e seleziona l'EFI prima di scaricare."
                : "Analyze hardware and select an EFI before downloading."
            return
        }
        let recommendations = analysis.kextRecommendations.filter {
            selectedKextRecommendations.contains($0.repository)
        }
        guard !recommendations.isEmpty else {
            errorMessage = language == .italian ? "Seleziona almeno un kext suggerito." : "Select at least one suggested kext."
            return
        }
        do {
            let states = try EFIManager(efiRoot: selectedEFI).kextStates()
            let catalog = Dictionary(uniqueKeysWithValues: SupportedKext.catalog.map { ($0.repository, $0) })
            var ordered: [SupportedKext] = []
            var visiting = Set<String>()
            var visited = Set<String>()

            func append(_ kext: SupportedKext) throws {
                guard !visited.contains(kext.repository) else { return }
                guard visiting.insert(kext.repository).inserted else { throw KextPlanError.dependencyCycle }
                for dependencyName in kext.requiredKexts {
                    if let enabled = states[dependencyName] {
                        guard enabled else { throw KextPlanError.disabledKext(dependencyName) }
                        continue
                    }
                    guard let dependency = SupportedKext.catalog.first(where: { $0.bundleName == dependencyName }) else {
                        throw KextPlanError.unsupportedDependency(dependencyName)
                    }
                    try append(dependency)
                }
                visiting.remove(kext.repository)
                visited.insert(kext.repository)
                if let enabled = states[kext.bundleName] {
                    guard enabled else { throw KextPlanError.disabledKext(kext.bundleName) }
                } else {
                    ordered.append(kext)
                }
            }

            for recommendation in recommendations {
                guard let kext = catalog[recommendation.repository] else {
                    throw KextPlanError.unsupportedRecommendation(recommendation.repository)
                }
                try append(kext)
            }
            guard !ordered.isEmpty else {
                errorMessage = language == .italian ? "I kext selezionati sono già attivi nell'EFI." : "Selected kexts are already enabled in this EFI."
                return
            }
            preparedRecommendedKexts.values.forEach { try? $0.removeStagingDirectory() }
            preparedRecommendedKexts.removeAll()
            recommendedKextPlanIDs = ordered.map(\.repository)
            isWorking = true
            statusMessage = AppStrings.text("work.download", language: language)
            Task {
                do {
                    for kext in ordered {
                        let prepared = try await KextReleaseService.prepare(kext)
                        preparedRecommendedKexts[kext.repository] = prepared
                    }
                    statusMessage = AppStrings.text("plan.ready", language: language)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isWorking = false
            }
        } catch let error as KextPlanError {
            errorMessage = error.localizedMessage(language: language)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installRecommendedKexts() {
        guard let selectedEFI else {
            errorMessage = language == .italian ? "Seleziona prima un volume EFI." : "Select an EFI volume first."
            return
        }
        let catalog = Dictionary(uniqueKeysWithValues: SupportedKext.catalog.map { ($0.repository, $0) })
        let items = recommendedKextPlanIDs.compactMap { repository -> KextInstallItem? in
            guard let kext = catalog[repository],
                  let prepared = preparedRecommendedKexts[repository] else { return nil }
            return KextInstallItem(kext: kext, prepared: prepared)
        }
        guard items.count == recommendedKextPlanIDs.count, !items.isEmpty else {
            errorMessage = language == .italian ? "Piano incompleto. Scarica di nuovo i kext." : "Plan is incomplete. Download the kexts again."
            return
        }
        installKextItems(items, efi: selectedEFI)
    }

    func openOfficialKextPage() {
        NSWorkspace.shared.open(selectedKext.releaseURL)
    }

    func explainKextCache() {
        statusMessage = AppStrings.text("cache.info", language: language)
    }

    func restartMac() {
        isWorking = true
        statusMessage = AppStrings.text("work.admin", language: language)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PrivilegedOperations.run("/sbin/shutdown -r now")
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func persistProfile() {
        defaults.set(computerModel, forKey: "pc.computerModel")
        defaults.set(motherboardModel, forKey: "pc.motherboardModel")
        defaults.set(macOSVersion, forKey: "pc.macOSVersion")
        defaults.set(otherHardwareInfo, forKey: "pc.otherHardwareInfo")
    }

    private func installKextItems(_ items: [KextInstallItem], efi: URL) {
        isWorking = true
        statusMessage = AppStrings.text("work.admin", language: language)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let manager = try EFIManager(efiRoot: efi)
                    let backup = try manager.install(items)
                    return (backup, try manager.summary())
                }.value
                efiSummary = result.1
                statusMessage = AppStrings.text("plan.installed", language: language) + result.0.lastPathComponent
                for item in items {
                    do {
                        try item.prepared.removeStagingDirectory()
                    } catch {
                        statusMessage += "\n\(error.localizedDescription)"
                    }
                }
                preparedKext = nil
                preparedKextID = nil
                preparedRecommendedKexts.removeAll()
                recommendedKextPlanIDs = []
                chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))
            } catch {
                errorMessage = error.localizedDescription
                chatMessages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            }
            isWorking = false
        }
    }

    private func runEFIAction(
        status: String,
        operation: @escaping @Sendable () throws -> (URL, String)
    ) {
        isWorking = true
        statusMessage = status
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: operation).value
                efiSummary = result.1
                statusMessage = AppStrings.text("plan.installed", language: language) + result.0.lastPathComponent
                chatMessages.append(ChatMessage(role: .assistant, text: statusMessage))
            } catch {
                errorMessage = error.localizedDescription
                chatMessages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            }
            isWorking = false
        }
    }

    private enum KextPlanError: LocalizedError {
        case dependencyCycle
        case disabledKext(String)
        case unsupportedDependency(String)
        case unsupportedRecommendation(String)

        var errorDescription: String? {
            switch self {
            case .dependencyCycle:
                "The kext catalog contains a dependency cycle."
            case .disabledKext(let name):
                "\(name) is present but disabled in OpenCore. Enable it before continuing."
            case .unsupportedDependency(let name):
                "Dependency is not in the supported catalog: \(name)."
            case .unsupportedRecommendation(let name):
                "Recommendation is outside the approved official catalog: \(name)."
            }
        }

        func localizedMessage(language: AppLanguage) -> String {
            let italian = language == .italian
            switch self {
            case .dependencyCycle:
                return italian ? "Il catalogo dei kext contiene una dipendenza circolare." : "The kext catalog contains a dependency cycle."
            case .disabledKext(let name):
                return italian ? "\(name) è presente ma disattivato in OpenCore. Attivalo prima di continuare." : "\(name) is present but disabled in OpenCore. Enable it before continuing."
            case .unsupportedDependency(let name):
                return italian ? "Dipendenza non inclusa nel catalogo supportato: \(name)." : "Dependency is not in the supported catalog: \(name)."
            case .unsupportedRecommendation(let name):
                return italian ? "Suggerimento fuori dal catalogo ufficiale approvato: \(name)." : "Recommendation is outside the approved official catalog: \(name)."
            }
        }
    }

    private enum ChatError: LocalizedError {
        case aiSettingsRequired

        var errorDescription: String? {
            "Choose an AI provider, model, and API key in Settings before chatting."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
