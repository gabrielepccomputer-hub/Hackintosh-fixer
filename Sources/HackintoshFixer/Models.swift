import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Google Gemini"

    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o"
        case .anthropic: "claude-sonnet-4-5"
        case .gemini: "gemini-2.5-flash"
        }
    }

    var keychainAccount: String {
        switch self {
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        }
    }

    var availableModels: [String] {
        switch self {
        case .openAI: ["gpt-4o", "gpt-4o-mini"]
        case .anthropic: ["claude-sonnet-4-5", "claude-3-7-sonnet-latest"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro"]
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case italian = "it"

    var id: String { rawValue }
}

struct ChatMessage: Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

struct AIAnalysis: Decodable, Sendable {
    let summary: String
    let recommendations: [Recommendation]
    let configChanges: [ConfigChange]
    let kextRecommendations: [KextRecommendation]

    private enum CodingKeys: String, CodingKey {
        case summary
        case recommendations
        case configChanges
        case kextRecommendations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        recommendations = try container.decodeIfPresent([Recommendation].self, forKey: .recommendations) ?? []
        configChanges = try container.decodeIfPresent([ConfigChange].self, forKey: .configChanges) ?? []
        kextRecommendations = try container.decodeIfPresent([KextRecommendation].self, forKey: .kextRecommendations) ?? []
    }
}

struct Recommendation: Decodable, Sendable {
    let title: String
    let reason: String
    let severity: String
}

struct ConfigChange: Decodable, Identifiable, Sendable {
    let bundlePath: String
    let enabled: Bool
    let reason: String

    var id: String { bundlePath }
}

struct KextRecommendation: Decodable, Identifiable, Sendable {
    let repository: String
    let reason: String

    var id: String { repository }
}
