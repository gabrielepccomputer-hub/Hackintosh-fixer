import Foundation

enum AIService {
    static func analyze(
        provider: AIProvider,
        model: String,
        apiKey: String,
        hardwareReport: String,
        efiSummary: String,
        profile: String,
        conversation: [ChatMessage],
        language: AppLanguage
    ) async throws -> AIAnalysis {
        guard !model.isEmpty,
              model.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw AIError.invalidModel
        }
        let transcript = conversation.suffix(12).map {
            "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
        }.joined(separator: "\n")
        let prompt = """
        You are a technical assistant for Intel Hackintosh and OpenCore. Reply in \(language == .italian ? "Italian" : "English").
        Analyze the hardware report, user-provided PC/macOS profile, recent conversation, and OpenCore summary.
        Never invent hardware or kexts. Propose config changes only for kexts already present in Kernel → Add and use their exact BundlePath.
        Never suggest shell commands, firmware changes, SMBIOS edits, or serial values. Never claim to have installed or changed anything.
        Recommend only kexts from these official repositories, and only when supported by the actual hardware evidence:
        \(SupportedKext.catalog.map(\.repository).joined(separator: ", "))
        If no concrete need can be established, return an empty kextRecommendations array.
        Return only valid JSON with this shape:
        {"summary":"...","recommendations":[{"title":"...","reason":"...","severity":"info|warning"}],"configChanges":[{"bundlePath":"Name.kext","enabled":true,"reason":"..."}],"kextRecommendations":[{"repository":"acidanthera/Lilu","reason":"..."}]}
        Do not include an installation recommendation if hardware details are insufficient. Mention uncertainty in summary.

        Hardware report (serial numbers and UUIDs removed):
        \(hardwareReport)

        User's PC profile:
        \(profile)

        Recent chat:
        \(transcript)

        OpenCore summary (not the full config.plist):
        \(efiSummary)
        """

        let request = try makeRequest(provider: provider, model: model, apiKey: apiKey, prompt: prompt)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 2_000_000 else { throw AIError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? "No response details."
            throw AIError.httpStatus(http.statusCode, String(details.prefix(800)))
        }
        let content = try extractContent(provider: provider, data: data)
        let json = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = json.data(using: .utf8) else { throw AIError.invalidJSON }
        do {
            let analysis = try JSONDecoder().decode(AIAnalysis.self, from: jsonData)
            guard analysis.recommendations.count <= 100,
                  analysis.configChanges.count <= 100,
                  analysis.kextRecommendations.count <= SupportedKext.catalog.count,
                  Set(analysis.configChanges.map(\.bundlePath)).count == analysis.configChanges.count,
                  Set(analysis.kextRecommendations.map(\.repository)).count == analysis.kextRecommendations.count,
                  analysis.configChanges.allSatisfy({ !$0.bundlePath.isEmpty && !$0.reason.isEmpty }),
                  analysis.kextRecommendations.allSatisfy({ recommendation in
                      SupportedKext.catalog.contains(where: { $0.repository == recommendation.repository })
                          && !recommendation.reason.isEmpty
                  }),
                  analysis.recommendations.allSatisfy({
                      !$0.title.isEmpty &&
                          !$0.reason.isEmpty &&
                          ["info", "warning"].contains($0.severity.lowercased())
                  }) else {
                throw AIError.invalidJSON
            }
            return analysis
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.invalidJSON
        }
    }

    private static func makeRequest(
        provider: AIProvider,
        model: String,
        apiKey: String,
        prompt: String
    ) throws -> URLRequest {
        var request: URLRequest
        var body: [String: Any]

        switch provider {
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": "Return only valid JSON, with no Markdown."],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.2,
                "response_format": ["type": "json_object"]
            ]
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": 1800,
                "system": "Return only valid JSON, with no Markdown.",
                "messages": [["role": "user", "content": prompt]]
            ]
        case .gemini:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com")!
            components.path = "/v1beta/models/\(model):generateContent"
            guard let url = components.url else { throw AIError.invalidResponse }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]
            ]
        }

        if provider == .openAI {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90
        return request
    }

    private static func extractContent(provider: AIProvider, data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }
        let content: String?
        switch provider {
        case .openAI:
            content = (((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]]
            content = blocks?.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        case .gemini:
            let parts = (((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])
            content = parts?.first?["text"] as? String
        }
        guard let content else { throw AIError.invalidResponse }
        return content
    }

    private enum AIError: LocalizedError {
        case invalidResponse
        case invalidJSON
        case invalidModel
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "The AI provider returned an unrecognized response."
            case .invalidJSON:
                "The AI did not return valid JSON. Try again or choose another model."
            case .invalidModel:
                "The model name contains invalid characters."
            case .httpStatus(let code, let details):
                "API error (\(code)): \(details)"
            }
        }
    }
}
