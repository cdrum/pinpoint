import Foundation

/// A vision-capable model available on OpenRouter.
struct OpenRouterModel: Identifiable, Hashable {
    let id: String              // e.g. "anthropic/claude-opus-4-8"
    let name: String
    /// Provider prefix, used as the "model family" grouping.
    var family: String { id.split(separator: "/").first.map(String.init) ?? "other" }
}

/// Calls OpenRouter's OpenAI-compatible chat/completions endpoint.
struct OpenRouterProvider: LLMProvider {

    func chat(system: String,
              messages: [ChatMessage],
              model: String,
              apiKey: String) async throws -> LLMResponse {
        var apiMessages: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            if let jpeg = message.imageJPEG {
                let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
                apiMessages.append([
                    "role": message.role.rawValue,
                    "content": [
                        ["type": "text", "text": message.text],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]
                ])
            } else {
                apiMessages.append(["role": message.role.rawValue, "content": message.text])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "usage": ["include": true],   // token + cost accounting
            "messages": apiMessages
        ]

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Pinpoint", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/cdrum/pinpoint", forHTTPHeaderField: "HTTP-Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PinpointError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw PinpointError.badResponse("HTTP \(http.statusCode): \(detail)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PinpointError.badResponse("Unexpected response shape")
        }

        var usage: LLMUsage?
        if let u = root["usage"] as? [String: Any] {
            usage = LLMUsage(promptTokens: (u["prompt_tokens"] as? Int) ?? 0,
                             completionTokens: (u["completion_tokens"] as? Int) ?? 0,
                             costUSD: (u["cost"] as? Double))
        }

        return LLMResponse(rawText: content, usage: usage)
    }

    /// Fetch the public catalog of models and keep the vision-capable ones.
    /// No API key required for this endpoint.
    static func fetchVisionModels() async throws -> [OpenRouterModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["data"] as? [[String: Any]] else { return [] }

        var models: [OpenRouterModel] = []
        for entry in array {
            guard let id = entry["id"] as? String else { continue }
            let name = (entry["name"] as? String) ?? id
            let architecture = entry["architecture"] as? [String: Any]
            let modalities = (architecture?["input_modalities"] as? [String]) ?? []
            if modalities.contains("image") {
                models.append(OpenRouterModel(id: id, name: name))
            }
        }
        return models.sorted { $0.id < $1.id }
    }
}
