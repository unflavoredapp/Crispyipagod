import CoreLocation
import SceneKit

/// Real road centerlines for a bounding box, converted into the scene's local coordinate
/// system so traffic can follow them instead of wandering randomly.
struct RoadNetwork {
    let polylines: [[SCNVector3]]
}

enum OverpassRoads {
    static func fetch(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, origin: (lat: Double, lon: Double)) async -> RoadNetwork? {
        let query = "[out:json][timeout:15];way[\"highway\"][\"highway\"!~\"footway|path|steps|cycleway|pedestrian|track|construction\"](\(minLat),\(minLon),\(maxLat),\(maxLon));out geom;"
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let encoded = "data=\(query)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        req.httpBody = encoded.data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return nil }

        let kx = 111320.0 * cos(origin.lat * .pi / 180), ky = 110540.0
        var lines: [[SCNVector3]] = []
        for el in elements {
            guard let geometry = el["geometry"] as? [[String: Any]] else { continue }
            var pts: [SCNVector3] = []
            for pt in geometry {
                guard let lat = pt["lat"] as? Double, let lon = pt["lon"] as? Double else { continue }
                let x = Float((lon - origin.lon) * kx)
                let z = Float(-(lat - origin.lat) * ky)
                pts.append(SCNVector3(x, 0, z))
            }
            if pts.count > 1 { lines.append(pts) }
        }
        return lines.isEmpty ? nil : RoadNetwork(polylines: lines)
    }
}
