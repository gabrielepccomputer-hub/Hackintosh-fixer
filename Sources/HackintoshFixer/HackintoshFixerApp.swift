import SwiftUI

@main
struct HackintoshFixerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 820, minHeight: 760)
        }
    }
}

private struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        Group {
            if app.hasCompletedOnboarding {
                ChatWorkspace(app: app)
            } else {
                OnboardingView(app: app)
            }
        }
        .environment(\.locale, Locale(identifier: app.language.rawValue))
    }
}

private struct OnboardingView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 22) {
                HStack {
                    Spacer()
                    LanguagePicker(app: app)
                }
                BrandHeader(app: app)
                HStack(spacing: 8) {
                    stepBadge("setup.step.profile", number: 1)
                    Capsule().fill(.white.opacity(0.35)).frame(width: 38, height: 2)
                    stepBadge("setup.step.ai", number: 2)
                }
                Group {
                    if app.onboardingStep == 0 {
                        profileStep
                    } else {
                        providerStep
                    }
                }
                .modifier(GlassSurface())
                .frame(maxWidth: 650)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(AppStrings.text("error.title", language: app.language), isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button(AppStrings.text("error.ok", language: app.language), role: .cancel) {
                app.errorMessage = nil
            }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppStrings.text("setup.profile.title", language: app.language))
                .font(.title.bold())
            Text(AppStrings.text("setup.profile.subtitle", language: app.language))
                .foregroundStyle(.secondary)
            TextField(AppStrings.text("setup.computer", language: app.language), text: $app.computerModel)
                .textFieldStyle(.roundedBorder)
            TextField(AppStrings.text("setup.motherboard", language: app.language), text: $app.motherboardModel)
                .textFieldStyle(.roundedBorder)
            TextField(AppStrings.text("setup.macos", language: app.language), text: $app.macOSVersion)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 7) {
                Text(AppStrings.text("setup.other", language: app.language))
                    .font(.callout.weight(.medium))
                TextEditor(text: $app.otherHardwareInfo)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Spacer()
                Button {
                    _ = app.saveDeviceProfile()
                } label: {
                    Label(AppStrings.text("setup.next", language: app.language), systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppStrings.text("setup.ai.title", language: app.language))
                .font(.title.bold())
            Text(AppStrings.text("setup.ai.subtitle", language: app.language))
                .foregroundStyle(.secondary)
            ProviderFields(app: app)
            HStack {
                Button {
                    app.onboardingStep = 0
                } label: {
                    Label(AppStrings.text("setup.back", language: app.language), systemImage: "arrow.left")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    app.completeOnboarding()
                } label: {
                    Label(AppStrings.text("setup.finish", language: app.language), systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func stepBadge(_ key: String, number: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "\(number).circle.fill")
            Text(AppStrings.text(key, language: app.language))
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(app.onboardingStep == number - 1 ? Color.accentColor : Color.secondary)
    }
}

private struct ChatWorkspace: View {
    @ObservedObject var app: AppModel
    @State private var showSettings = false
    @State private var showApplyConfirmation = false
    @State private var showInstallConfirmation = false
    @State private var showRestartConfirmation = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(.white.opacity(0.15))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !app.computerModel.isEmpty || !app.motherboardModel.isEmpty {
                            profileSummary.modifier(GlassSurface())
                        }
                        ForEach(app.chatMessages) { message in
                            ChatBubble(message: message)
                        }
                        if app.isWorking {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(app.statusMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .modifier(GlassSurface())
                        }
                        if app.analysis != nil {
                            analysisPanel.modifier(GlassSurface())
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                composer
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(app: app)
                .frame(minWidth: 620, minHeight: 650)
        }
        .alert(AppStrings.text("error.title", language: app.language), isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button(AppStrings.text("error.ok", language: app.language), role: .cancel) {
                app.errorMessage = nil
            }
        } message: {
            Text(app.errorMessage ?? "")
        }
        .confirmationDialog(
            AppStrings.text("analysis.apply_confirm", language: app.language),
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppStrings.text("analysis.apply_button", language: app.language)) {
                app.applySelectedChanges()
            }
            Button(AppStrings.text("setup.back", language: app.language), role: .cancel) {}
        } message: {
            Text(AppStrings.text("analysis.apply_message", language: app.language))
        }
        .confirmationDialog(
            AppStrings.text("analysis.install_confirm", language: app.language),
            isPresented: $showInstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppStrings.text("analysis.install_button", language: app.language)) {
                app.installRecommendedKexts()
            }
            Button(AppStrings.text("setup.back", language: app.language), role: .cancel) {}
        } message: {
            Text(AppStrings.text("analysis.install_message", language: app.language))
        }
        .confirmationDialog(
            AppStrings.text("maintenance.restart_confirm", language: app.language),
            isPresented: $showRestartConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppStrings.text("maintenance.restart_button", language: app.language), role: .destructive) {
                app.restartMac()
            }
            Button(AppStrings.text("setup.back", language: app.language), role: .cancel) {}
        } message: {
            Text(AppStrings.text("maintenance.restart_message", language: app.language))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.text("chat.title", language: app.language))
                    .font(.headline)
                Text("\(app.provider.rawValue) · \(app.modelName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.scanHardware()
            } label: {
                Label(AppStrings.text("chat.scan", language: app.language), systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .disabled(app.isWorking)
            Button {
                app.chooseEFI()
            } label: {
                Label(AppStrings.text("chat.choose_efi", language: app.language), systemImage: "externaldrive")
            }
            .buttonStyle(.bordered)
            Button {
                showSettings = true
            } label: {
                Label(AppStrings.text("chat.settings", language: app.language), systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .modifier(GlassSurface())
    }

    private var profileSummary: some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text([app.computerModel, app.motherboardModel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.headline)
                Text("macOS \(app.macOSVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let selectedEFI = app.selectedEFI {
                Label(selectedEFI.lastPathComponent, systemImage: "externaldrive.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField(AppStrings.text("chat.placeholder", language: app.language), text: $app.chatInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit {
                    app.sendChatMessage()
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            Button {
                app.sendChatMessage()
            } label: {
                Label(AppStrings.text("chat.send", language: app.language), systemImage: "arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isWorking || app.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .modifier(GlassSurface())
    }

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(AppStrings.text("analysis.title", language: app.language), systemImage: "sparkles")
                .font(.title2.bold())
            if !app.analysis!.recommendations.isEmpty {
                Text(AppStrings.text("analysis.recommendations", language: app.language))
                    .font(.headline)
                ForEach(Array(app.analysis!.recommendations.enumerated()), id: \.offset) { _, recommendation in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("[\(recommendation.severity.uppercased())] \(recommendation.title)")
                            .font(.headline)
                        Text(recommendation.reason)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !app.analysis!.kextRecommendations.isEmpty {
                Text(AppStrings.text("analysis.kexts", language: app.language))
                    .font(.headline)
                Text(AppStrings.text("analysis.kexts.note", language: app.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(app.analysis!.kextRecommendations) { recommendation in
                    let kext = SupportedKext.catalog.first(where: { $0.repository == recommendation.repository })
                    Toggle(isOn: Binding(
                        get: { app.selectedKextRecommendations.contains(recommendation.repository) },
                        set: { selected in
                            if selected {
                                app.selectedKextRecommendations.insert(recommendation.repository)
                            } else {
                                app.selectedKextRecommendations.remove(recommendation.repository)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kext?.displayName ?? recommendation.repository).font(.headline)
                            Text(recommendation.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Button(AppStrings.text("analysis.download", language: app.language)) {
                    app.downloadRecommendedKexts()
                }
                .buttonStyle(.bordered)
                .disabled(app.selectedKextRecommendations.isEmpty || app.selectedEFI == nil || app.isWorking)
            }
            if !app.recommendedKextPlanIDs.isEmpty {
                Text(AppStrings.text("analysis.plan", language: app.language))
                    .font(.headline)
                ForEach(app.recommendedKextPlanIDs, id: \.self) { repository in
                    let name = SupportedKext.catalog.first(where: { $0.repository == repository })?.bundleName ?? repository
                    let prepared = app.preparedRecommendedKexts[repository]
                    Label(
                        "\(name)\(prepared.map { " · \($0.version)" } ?? "")",
                        systemImage: prepared == nil ? "arrow.down.circle" : "checkmark.circle.fill"
                    )
                }
                Button(AppStrings.text("analysis.install", language: app.language)) {
                    showInstallConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    app.preparedRecommendedKexts.count != app.recommendedKextPlanIDs.count ||
                        app.isWorking ||
                        app.selectedEFI == nil
                )
            }
            if !app.analysis!.configChanges.isEmpty {
                Text(AppStrings.text("analysis.config", language: app.language))
                    .font(.headline)
                ForEach(app.analysis!.configChanges) { change in
                    Toggle(isOn: Binding(
                        get: { app.selectedChanges.contains(change.bundlePath) },
                        set: { selected in
                            if selected {
                                app.selectedChanges.insert(change.bundlePath)
                            } else {
                                app.selectedChanges.remove(change.bundlePath)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                "\(change.bundlePath) → \(AppStrings.text(change.enabled ? "analysis.enabled" : "analysis.disabled", language: app.language))"
                            )
                                .font(.system(.body, design: .monospaced))
                            Text(change.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Button(AppStrings.text("analysis.apply", language: app.language)) {
                    showApplyConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.selectedChanges.isEmpty || app.selectedEFI == nil || app.isWorking)
            }
            HStack {
                Label(AppStrings.text("hardware.title", language: app.language), systemImage: "cpu")
                Spacer()
                Label(AppStrings.text("efi.title", language: app.language), systemImage: "externaldrive")
            }
            .font(.caption.weight(.semibold))
            if !app.hardwareReport.isEmpty {
                Text(app.hardwareReport)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxHeight: 130)
            }
            if !app.efiSummary.isEmpty {
                Text(app.efiSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Text(AppStrings.text("maintenance.cache", language: app.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(AppStrings.text("maintenance.restart", language: app.language)) {
                    showRestartConfirmation = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsView: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(AppStrings.text("settings.title", language: app.language))
                            .font(.largeTitle.bold())
                        Spacer()
                        Button(AppStrings.text("settings.close", language: app.language)) {
                            dismiss()
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AppStrings.text("settings.language", language: app.language))
                            .font(.headline)
                        LanguagePicker(app: app)
                    }
                    .modifier(GlassSurface())
                    VStack(alignment: .leading, spacing: 12) {
                        Label(AppStrings.text("settings.profile", language: app.language), systemImage: "desktopcomputer")
                            .font(.headline)
                        ProfileFields(app: app)
                    }
                    .modifier(GlassSurface())
                    VStack(alignment: .leading, spacing: 12) {
                        Label(AppStrings.text("settings.ai", language: app.language), systemImage: "sparkles")
                            .font(.headline)
                        ProviderFields(app: app)
                    }
                    .modifier(GlassSurface())
                    HStack {
                        Spacer()
                        Button(AppStrings.text("api.save", language: app.language)) {
                            if app.saveSettings() {
                                dismiss()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .alert(AppStrings.text("error.title", language: app.language), isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button(AppStrings.text("error.ok", language: app.language), role: .cancel) {
                app.errorMessage = nil
            }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

private struct ProviderFields: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Picker(AppStrings.text("provider", language: app.language), selection: Binding(
            get: { app.provider },
            set: { app.changeProvider($0) }
        )) {
            ForEach(AIProvider.allCases) { provider in
                Text(provider.rawValue).tag(provider)
            }
        }
        Picker(AppStrings.text("model", language: app.language), selection: $app.modelName) {
            ForEach(app.provider.availableModels, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        SecureField(AppStrings.text("api.key", language: app.language), text: $app.apiKey)
            .textFieldStyle(.roundedBorder)
    }
}

private struct ProfileFields: View {
    @ObservedObject var app: AppModel

    var body: some View {
        TextField(AppStrings.text("setup.computer", language: app.language), text: $app.computerModel)
            .textFieldStyle(.roundedBorder)
        TextField(AppStrings.text("setup.motherboard", language: app.language), text: $app.motherboardModel)
            .textFieldStyle(.roundedBorder)
        TextField(AppStrings.text("setup.macos", language: app.language), text: $app.macOSVersion)
            .textFieldStyle(.roundedBorder)
        TextField(AppStrings.text("setup.other", language: app.language), text: $app.otherHardwareInfo, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
    }
}

private struct LanguagePicker: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Picker(AppStrings.text("settings.language", language: app.language), selection: Binding(
            get: { app.language },
            set: { app.setLanguage($0) }
        )) {
            Text(AppStrings.text("language.english", language: app.language)).tag(AppLanguage.english)
            Text(AppStrings.text("language.italian", language: app.language)).tag(AppLanguage.italian)
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }
}

private struct BrandHeader: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Color.accentColor.gradient)
                .frame(width: 82, height: 82)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            Text(AppStrings.text("app.title", language: app.language))
                .font(.largeTitle.bold())
            Text(AppStrings.text("app.subtitle", language: app.language))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 80) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: 690, alignment: .leading)
                .background(
                    isUser ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 18)
                )
            if !isUser { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.13),
                Color(nsColor: .windowBackgroundColor),
                Color.purple.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct GlassSurface: ViewModifier {
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .padding(18)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            fallback(content)
        }
#else
        fallback(content)
#endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
    }
}
