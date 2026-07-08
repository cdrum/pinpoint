import Foundation

/// Parses the machine-readable `LOCATION:` line that every assistant reply ends
/// with, separating it from the conversational prose shown to the user.
///
/// Expected final line:
///   LOCATION: {"place_name": "Puerta del Sol, Madrid, Spain", "confidence": 0.85}
/// or:
///   LOCATION: none
enum LocationParsing {
    struct Extraction {
        /// The reply with the LOCATION line removed — shown in the transcript.
        let display: String
        /// The extracted place, if the model committed to one this turn.
        let placeName: String?
        let confidence: Double
    }

    static func extract(from text: String) -> Extraction {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Find the last line that starts with "LOCATION:" (case-insensitive).
        guard let index = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).range(of: "^location:", options: [.regularExpression, .caseInsensitive]) != nil
        }) else {
            return Extraction(display: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              placeName: nil, confidence: 0)
        }

        let locationLine = lines.remove(at: index)
        let display = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Everything after the "LOCATION:" keyword.
        guard let colon = locationLine.range(of: "location:", options: .caseInsensitive) else {
            return Extraction(display: display, placeName: nil, confidence: 0)
        }
        let payload = locationLine[colon.upperBound...].trimmingCharacters(in: .whitespaces)

        if payload.lowercased() == "none" || payload.isEmpty {
            return Extraction(display: display, placeName: nil, confidence: 0)
        }

        // Strip code fences if the model wrapped the JSON.
        var json = payload
        if json.hasPrefix("```") {
            json = json.replacingOccurrences(of: "```json", with: "")
                       .replacingOccurrences(of: "```", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let place = obj["place_name"] as? String, !place.isEmpty {
            let confidence: Double
            if let d = obj["confidence"] as? Double { confidence = d }
            else if let s = obj["confidence"] as? String, let d = Double(s) { confidence = d }
            else { confidence = 0 }
            return Extraction(display: display, placeName: place, confidence: confidence)
        }

        return Extraction(display: display, placeName: nil, confidence: 0)
    }
}
