import Foundation
import CoreLocation
import MapKit

/// Resolves a place name to coordinates.
///
/// Primary: `MKLocalSearch` — Apple Maps' point-of-interest search, which
/// handles landmark/building names ("Puerta del Sol, Madrid, Spain") far better
/// than address geocoding. Falls back to `CLGeocoder` for plain addresses.
enum Geocoding {
    static func resolve(_ placeName: String) async -> CLLocationCoordinate2D? {
        let trimmed = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest, .address]
        if let response = try? await MKLocalSearch(request: request).start(),
           let item = response.mapItems.first {
            return item.placemark.coordinate
        }

        if let placemarks = try? await CLGeocoder().geocodeAddressString(trimmed),
           let coordinate = placemarks.first?.location?.coordinate {
            return coordinate
        }
        return nil
    }
}
