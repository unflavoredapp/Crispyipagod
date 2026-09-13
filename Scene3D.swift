import SwiftUI
import WebKit
import CoreLocation

// MARK: - Config

enum Basemap: String, CaseIterable, Identifiable, Codable {
    case esriImagery, esriHybrid, esriStreets, osm, google3D, bingAerial, bingHybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .esriImagery: return "Esri Imagery"
        case .esriHybrid: return "Esri Hybrid"
        case .esriStreets: return "Esri Streets"
        case .osm: return "OSM"
        case .google3D: return "Google 3D"
        case .bingAerial: return "Bing Aerial"
        case .bingHybrid: return "Bing Hybrid"
        }
    }
    var icon: String {
        switch self {
        case .esriImagery, .bingAerial: return "globe.americas.fill"
        case .esriHybrid, .bingHybrid: return "map.fill"
        case .esriStreets, .osm: return "map"
        case .google3D: return "building.2.crop.circle"
        }
    }
    /// Needs a Cesium ion token (Google Photorealistic 3D Tiles and Bing are served through ion).
    var needsIon: Bool { self == .google3D || self == .bingAerial || self == .bingHybrid }
}

enum CesiumConfig {
    static let cesiumVersion = "1.122"
    /// Fallback ion token so nothing breaks if Settings is empty. Paste yours in Settings → 3D Scene.
    static var defaultIonToken: String { BundledKeys.cesiumIon }
    static let googleTilesAsset = 2275207      // Google Photorealistic 3D Tiles via ion
    static let osmBuildingsAsset = 96188       // Cesium OSM Buildings
    /// Fallback Google Map Tiles API key (Photorealistic 3D without ion). Settings → 3D Scene overrides.
    static var defaultGoogleKey: String { BundledKeys.googleMapTiles }
}

enum SceneTool: String, CaseIterable, Identifiable {
    case none, measure, los, probe, scan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Inspect"
        case .measure: return "Measure"
        case .los: return "Line of sight"
        case .probe: return "Height probe"
        case .scan: return "Scan radius"
        }
    }
    var icon: String {
        switch self {
        case .none: return "hand.tap"
        case .measure: return "ruler"
        case .los: return "eye"
        case .probe: return "arrow.up.and.down"
        case .scan: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Hand-rolled tiles catalog (godseye-tiles)

struct TilesCatalog: Decodable, Equatable {
    struct Raster: Decodable, Equatable, Identifiable { let id: String; let name: String; let url: String; let minZoom: Int; let maxZoom: Int; let bbox: [Double]; let credit: String? }
    struct Tileset: Decodable, Equatable, Identifiable { let id: String; let name: String; let url: String; let bbox: [Double]; let credit: String?; let baseHeight: Double?; let kind: String? }
    var rasters: [Raster] = []
    var tilesets: [Tileset] = []
    var models: String? = nil

    static func load(_ url: String) async -> TilesCatalog? {
        guard let u = URL(string: url), !url.isEmpty else { return nil }
        guard let data = await RealismTileCache.data(for: u, maxAge: 15 * 60) else { return nil }
        return try? JSONDecoder().decode(TilesCatalog.self, from: data)
    }
}

// NOTE: the CesiumJS/WebKit world (Scene3DView) was removed — RealismSceneView
// (RealismView.swift) is now the single 3D world. Basemap/CesiumConfig/TilesCatalog
// above are still used by Settings and by the tile-streaming pipeline.
