import Foundation

/// A reference photo from Pexels, used for visual comparison.
struct PexelsPhoto: Identifiable, Hashable {
    let id: Int
    let thumbURL: URL
    let pageURL: URL       // Pexels page (attribution requires linking back)
    let photographer: String
}

/// Searches pexels.com for stock photos of a place, so the user can compare
/// them against the photo being located. Attribution is required — always show
/// the photographer and link to the Pexels page.
struct PexelsProvider {
    static func search(_ query: String, apiKey: String, perPage: Int = 12) async throws -> [PexelsPhoto] {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.pexels.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PinpointError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw PinpointError.badResponse("Pexels HTTP \(http.statusCode): \(detail)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = root["photos"] as? [[String: Any]] else { return [] }

        return photos.compactMap { entry in
            guard let id = entry["id"] as? Int,
                  let src = entry["src"] as? [String: Any],
                  let thumb = (src["medium"] as? String) ?? (src["small"] as? String),
                  let thumbURL = URL(string: thumb),
                  let page = entry["url"] as? String,
                  let pageURL = URL(string: page) else { return nil }
            let photographer = (entry["photographer"] as? String) ?? "Pexels"
            return PexelsPhoto(id: id, thumbURL: thumbURL, pageURL: pageURL, photographer: photographer)
        }
    }
}
