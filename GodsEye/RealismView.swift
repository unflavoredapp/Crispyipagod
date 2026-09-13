import SwiftUI
import SceneKit
import ModelIO
import CoreLocation
import UIKit

// MARK: - Realism 3D (native) — the 2D map's look, in 3D, from our own tiles

struct RealismSceneView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scene: SCNScene?
    @State private var status = "Loading realism tiles…"
    @State private var preset = "auto"
    @State private var loaded: [String] = []
    @State private var trafficOn = false
    @State private var trafficBounds: TrafficSimulator.Bounds?
    @State private var ground: GroundGrid?
    @State private var weatherNow: WeatherNow?
    @State private var sceneOrigin: (lat: Double, lon: Double) = (0, 0)
    @State private var scnView: SCNView?
    @State private var photoMode = false
    @State private var capturedImage: UIImage?
    @State private var showShare = false
    @State private var ufoActive = false
    private let streamer = TerrainStreamer()
    private let traffic = TrafficSimulator()
    private let presets: [(String, String, String)] = [("auto", "Auto", "sun.and.horizon.fill"), ("day", "Day", "sun.max.fill"), ("golden", "Golden", "sunset.fill"), ("night", "Night", "moon.stars.fill"), ("overcast", "Overcast", "cloud.fill")]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let scene { RealismSCNView(scene: scene, onFocusMoved: { focal in
                streamer.ensureLoaded(focal: focal, origin: sceneOrigin)
                scene.rootNode.childNode(withName: "weatherFX", recursively: false)?.position = SCNVector3(focal.x, focal.y + 40, focal.z)
            }, onViewReady: { scnView = $0 }).ignoresSafeArea() }
            else {
                VStack(spacing: 10) { ProgressView().tint(.yellow); Text(status).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 6) {
                if !photoMode {
                HStack(spacing: 8) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36).background(Circle().fill(.ultraThinMaterial)) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(presets, id: \.0) { p in
                                Button { preset = p.0; if let scene { RealismStage.apply(preset, to: scene, lat: s.center.latitude, lon: s.center.longitude) } } label: {
                                    HStack(spacing: 5) { Image(systemName: p.2); Text(p.1).font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                                        .padding(.horizontal, 10).padding(.vertical, 8)
                                        .foregroundStyle(preset == p.0 ? Color.black : Color.primary)
                                        .background(Capsule().fill(preset == p.0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.ultraThinMaterial)))
                                }
                                .buttonStyle(.plain)
                            }
                            Button { toggleTraffic() } label: {
                                HStack(spacing: 5) { Image(systemName: "car.2.fill"); Text("Traffic").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(trafficOn ? Color.black : Color.primary)
                                    .background(Capsule().fill(trafficOn ? AnyShapeStyle(Color.green) : AnyShapeStyle(.ultraThinMaterial)))
                            }
                            .buttonStyle(.plain)
                            .disabled(scene == nil || trafficBounds == nil)
                            Button { spawnUFO() } label: {
                                HStack(spacing: 5) { Image(systemName: "sparkles"); Text("UFO").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(ufoActive ? Color.black : Color.primary)
                                    .background(Capsule().fill(ufoActive ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.ultraThinMaterial)))
                            }
                            .buttonStyle(.plain)
                            .disabled(scene == nil || ufoActive)
                            Button { photoMode = true } label: {
                                Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(.primary)
                                    .background(Circle().fill(.ultraThinMaterial))
                            }
                            .buttonStyle(.plain)
                            .disabled(scene == nil)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6)
                HStack {
                    Text(loaded.isEmpty ? status : "REALISM · " + loaded.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                }
            }
            .foregroundStyle(.white)

            if photoMode {
                VStack {
                    Spacer()
                    HStack(spacing: 28) {
                        Button { photoMode = false } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 44).background(Circle().fill(.ultraThinMaterial))
                        }
                        Button { capturePhoto() } label: {
                            Circle().fill(.white).frame(width: 62, height: 62)
                                .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 3).padding(3))
                        }
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.bottom, 28)
                }
                .foregroundStyle(.white)
            }
        }
        .sheet(isPresented: $showShare) {
            if let capturedImage { ActivityShareSheet(items: [capturedImage]) }
        }
        .preferredColorScheme(.dark)
        .task { await build() }
        .onDisappear { traffic.remove() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if preset == "auto", let scene { RealismStage.apply(preset, to: scene, lat: s.center.latitude, lon: s.center.longitude) }
        }
    }

    private func toggleTraffic() {
        guard let scene, let bounds = trafficBounds else { return }
        trafficOn.toggle()
        if trafficOn {
            s.awardXP(.trafficWatch)
            // building-tile count already loaded is a real, honest proxy for local density —
            // there's no free keyless population-grid API, but this scales with actual built-up area
            let buildingTileCount = scene.rootNode.childNodes.filter { ($0.name ?? "").hasPrefix("b_") }.count
            let density = min(1.0, Double(buildingTileCount) / 9.0)
            let origin = sceneOrigin
            // instant feedback first (random waypoints), then upgrade in place once real roads load
            traffic.populate(in: scene, ground: ground, bounds: bounds, roads: nil, populationDensity: density)
            Task {
                let kx = 111320.0 * cos(origin.lat * .pi / 180), ky = 110540.0
                let latA = origin.lat - Double(bounds.minZ) / ky, latB = origin.lat - Double(bounds.maxZ) / ky
                let lonA = origin.lon + Double(bounds.minX) / kx, lonB = origin.lon + Double(bounds.maxX) / kx
                let roads = await OverpassRoads.fetch(minLat: min(latA, latB), minLon: min(lonA, lonB), maxLat: max(latA, latB), maxLon: max(lonA, lonB), origin: origin)
                await MainActor.run {
                    guard trafficOn, let scene, roads != nil else { return }
                    traffic.populate(in: scene, ground: ground, bounds: bounds, roads: roads, populationDensity: density)
                }
            }
        } else {
            traffic.remove()
        }
    }

    private func capturePhoto() {
        guard let img = scnView?.snapshot() else { return }
        capturedImage = img
        showShare = true
        s.recordPhotoTaken()
    }

    private func spawnUFO() {
        guard let scene, let bounds = trafficBounds else { return }
        ufoActive = true
        UFOEncounter.spawn(in: scene, ground: ground, bounds: bounds) {
            ufoActive = false
            s.recordUFOSighting()
        }
    }

    private func build() async {
        let c = s.center
        guard let cat = await TilesCatalog.load(s.tilesCatalogURL) else { status = "Tiles catalog not reachable — run the godseye-tiles workflow (mesh + buildings + trees) for this area."; return }
        func covering(_ kind: String) -> TilesCatalog.Tileset? {
            cat.tilesets.first { $0.kind == kind && $0.bbox.count == 4 && c.longitude >= $0.bbox[0] && c.longitude <= $0.bbox[2] && c.latitude >= $0.bbox[1] && c.latitude <= $0.bbox[3] }
        }
        guard let mesh = covering("mesh") ?? covering("buildings") else { status = "No realism tiles cover this spot yet.\nRun Build tiles (all) for \(String(format: "%.4f, %.4f", c.latitude, c.longitude))."; return }
        let area = mesh.id.split(separator: "/").first.map(String.init) ?? ""
        ObjLoader.foliageSeason = Season.current(latitude: c.latitude)
        let sc = SCNScene()
        let root = SCNNode(); root.name = "world"; sc.rootNode.addChildNode(root)
        var ground: GroundGrid? = nil
        var origin: (lat: Double, lon: Double) = (c.latitude, c.longitude)

        if let m = covering("mesh"), m.id.hasPrefix(area) {
            status = "Loading lidar/NAIP mesh…"
            if let (meta, base) = await TileMeta.load(m.url) {
                origin = (meta.center[0], meta.center[1])
                ground = await GroundGrid.load(base.appendingPathComponent("ground.json"))
                let n = await ObjLoader.loadMeshTiles(base: base, meta: meta, around: c, style: .ortho)
                if !n.childNodes.isEmpty {
                    let names = n.childNodes.compactMap(\.name)
                    for child in Array(n.childNodes) { root.addChildNode(child) }
                    loaded.append("MESH")
                    let kx0 = 111320.0 * cos(meta.center[0] * .pi / 180), ky0 = 110540.0
                    let x0 = (c.longitude - meta.center[1]) * kx0, y0 = (c.latitude - meta.center[0]) * ky0
                    let i0 = Int(floor((x0 + meta.half) / meta.tileM)), j0 = Int(floor((meta.half - y0) / meta.tileM))
                    streamer.register(kind: "mesh", prefix: "m", base: base, meta: meta, style: .ortho, initiallyLoaded: names, initialIndex: (i0, j0))
                    s.recordDiscoveredTiles(names)
                }
            }
        }
        if let b = covering("buildings"), b.id.hasPrefix(area) {
            status = "Loading buildings…"
            if let (meta, base) = await TileMeta.load(b.url) {
                let n = await ObjLoader.loadGridTiles(base: base, prefix: "b", meta: meta, around: c, style: .pbr, ground: ground)
                if !n.childNodes.isEmpty {
                    let names = n.childNodes.compactMap(\.name)
                    for child in Array(n.childNodes) { root.addChildNode(child) }
                    loaded.append("BUILDINGS")
                    let kx0 = 111320.0 * cos(meta.center[0] * .pi / 180), ky0 = 110540.0
                    let x0 = (c.longitude - meta.center[1]) * kx0, y0 = (c.latitude - meta.center[0]) * ky0
                    let i0 = Int(floor(x0 / meta.tileM)), j0 = Int(floor(y0 / meta.tileM))
                    streamer.register(kind: "buildings", prefix: "b", base: base, meta: meta, style: .pbr, initiallyLoaded: names, initialIndex: (i0, j0))
                    s.recordDiscoveredTiles(names)
                }
            }
        }
        if let t = covering("trees"), t.id.hasPrefix(area) {
            status = "Loading vegetation…"
            if let (meta, base) = await TileMeta.load(t.url) {
                let n = await ObjLoader.loadGridTiles(base: base, prefix: "t", meta: meta, around: c, style: .trees, ground: ground)
                if !n.childNodes.isEmpty {
                    let names = n.childNodes.compactMap(\.name)
                    for child in Array(n.childNodes) { root.addChildNode(child) }
                    loaded.append("TREES")
                    let kx0 = 111320.0 * cos(meta.center[0] * .pi / 180), ky0 = 110540.0
                    let x0 = (c.longitude - meta.center[1]) * kx0, y0 = (c.latitude - meta.center[0]) * ky0
                    let i0 = Int(floor(x0 / meta.tileM)), j0 = Int(floor(y0 / meta.tileM))
                    streamer.register(kind: "trees", prefix: "t", base: base, meta: meta, style: .trees, initiallyLoaded: names, initialIndex: (i0, j0))
                    s.recordDiscoveredTiles(names)
                }
            }
        }
        if ground == nil {
            // no lidar: a matte ground plane so buildings/trees don't float in the void
            let g = SCNNode(geometry: SCNPlane(width: 6000, height: 6000)); g.eulerAngles.x = -.pi / 2; g.position.y = -0.05
            g.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.20, green: 0.26, blue: 0.16, alpha: 1); g.geometry?.firstMaterial?.roughness.contents = 1.0
            root.addChildNode(g)
        }
        // focus on the map centre in area-local coords (x east, z south)
        let kx = 111320.0 * cos(origin.lat * .pi / 180), ky = 110540.0
        let fx = Float((c.longitude - origin.lon) * kx), fz = Float(-(c.latitude - origin.lat) * ky)
        let fy = ground?.height(x: Double(fx), y: Double(-fz)) ?? 0
        RealismStage.setup(sc, focus: SCNVector3(fx, Float(fy), fz), distance: Float(max(120, min(s.distance, 1200))))
        RealismStage.apply(preset, to: sc, lat: c.latitude, lon: c.longitude)
        if let w = await OpenMeteo.current(lat: c.latitude, lon: c.longitude) {
            weatherNow = w
            WeatherFX.apply(w, to: sc, focus: SCNVector3(fx, Float(fy), fz))
        }
        streamer.configure(root: root, ground: ground)
        streamer.onTilesLoaded = { [s] names in s.recordDiscoveredTiles(names) }
        self.sceneOrigin = origin
        scene = sc
        self.ground = ground
        let (minB, maxB) = root.boundingBox
        if maxB.x > minB.x, maxB.z > minB.z {
            // shrink slightly off the outer edge so agents don't spawn floating past loaded tiles
            let pad: Float = 15
            trafficBounds = (minB.x + pad, maxB.x - pad, minB.z + pad, maxB.z - pad)
        }
        if loaded.isEmpty { status = "Tiles listed but nothing loaded for this spot" }
        else { s.awardXP(.openRealism) }
    }
}

// MARK: - Tile metadata / ground grid

struct TileMeta {
    let center: [Double]; let tileM: Double; let half: Double
    static func load(_ tilesetURL: String) async -> (TileMeta, URL)? {
        guard let base = URL(string: tilesetURL)?.deletingLastPathComponent(),
              let d = await RealismTileCache.data(for: base.appendingPathComponent("meta.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let center = j["center"] as? [Double], center.count == 2,
              let tileM = j["tileM"] as? Double, let half = j["half"] as? Double else { return nil }
        return (TileMeta(center: center, tileM: tileM, half: half), base)
    }
}

final class GroundGrid {
    let cell: Double; let half: Double; let rows: Int; let cols: Int; let z: [[Double]]
    init?(json: [String: Any]) {
        guard let cell = json["cell"] as? Double, let half = json["half"] as? Double, let rows = json["rows"] as? Int, let cols = json["cols"] as? Int, let z = json["z"] as? [[Double]] else { return nil }
        self.cell = cell; self.half = half; self.rows = rows; self.cols = cols; self.z = z
    }
    static func load(_ url: URL) async -> GroundGrid? {
        guard let d = await RealismTileCache.data(for: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return GroundGrid(json: j)
    }
    /// x east, y north (metres from area centre) → ground height (metres, mesh-local).
    func height(x: Double, y: Double) -> Double {
        let c = Int(((x + half) / cell).rounded()), r = Int(((half - y) / cell).rounded())
        guard r >= 0, r < rows, c >= 0, c < cols, r < z.count, c < z[r].count else { return 0 }
        return z[r][c]
    }
}

// MARK: - OBJ loader (tiny, fast, per-group so we can drop objects onto the terrain)

enum ObjStyle { case ortho, pbr, trees }

enum ObjLoader {
    /// Set once per build() from the real date + latitude — see Season (WorldSim.swift).
    static var foliageSeason: Season = .summer
    struct Group { var name: String; var material: String; var v: [SCNVector3] = []; var uv: [CGPoint] = []; var idx: [Int32] = [] }

    static func parse(_ text: String) -> [Group] {
        var verts: [SCNVector3] = [], uvs: [CGPoint] = []
        var groups: [Group] = []; var cur = Group(name: "default", material: "default")
        var map: [Int: Int32] = [:]   // global vertex index -> local
        func flush() { if !cur.idx.isEmpty { groups.append(cur) } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("v ") {
                let p = line.split(separator: " "); if p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) { verts.append(SCNVector3(x, y, z)) }
            } else if line.hasPrefix("vt ") {
                let p = line.split(separator: " "); if p.count >= 3, let u = Double(p[1]), let v = Double(p[2]) { uvs.append(CGPoint(x: u, y: v)) }
            } else if line.hasPrefix("g ") {
                flush(); cur = Group(name: String(line.dropFirst(2)), material: cur.material); map = [:]
            } else if line.hasPrefix("usemtl ") {
                let m = String(line.dropFirst(7)); if m != cur.material && !cur.idx.isEmpty { flush(); cur = Group(name: cur.name, material: m); map = [:] } else { cur.material = m }
            } else if line.hasPrefix("f ") {
                let p = line.split(separator: " ").dropFirst()
                var tri: [Int32] = []
                for tok in p {
                    let parts = tok.split(separator: "/", omittingEmptySubsequences: false)
                    guard let vi = Int(parts[0]) else { continue }
                    let ti = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                    let key = vi * 1_000_003 + ti
                    if let l = map[key] { tri.append(l) } else {
                        let l = Int32(cur.v.count); map[key] = l
                        cur.v.append(verts[vi - 1]); cur.uv.append(ti > 0 && ti - 1 < uvs.count ? uvs[ti - 1] : .zero); tri.append(l)
                    }
                }
                if tri.count >= 3 { for k in 1..<(tri.count - 1) { cur.idx += [tri[0], tri[k], tri[k + 1]] } }
            }
        }
        flush(); return groups
    }

    static func material(for name: String, style: ObjStyle, base: URL, tile: String, cache: inout [String: SCNMaterial]) async -> SCNMaterial {
        let key = style == .ortho ? tile : name
        if let m = cache[key] { return m }
        let m = SCNMaterial(); m.lightingModel = .physicallyBased; m.isDoubleSided = false
        switch style {
        case .ortho:
            if let d = await RealismTileCache.data(for: base.appendingPathComponent("\(tile).jpg")), let img = UIImage(data: d) { m.diffuse.contents = img }
            m.roughness.contents = 0.95; m.metalness.contents = 0.0
            sharpen(m.diffuse)
        case .pbr:
            if let d = await RealismTileCache.data(for: base.appendingPathComponent("tex_\(name).png")), let img = UIImage(data: d) { m.diffuse.contents = img; m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat }
            if let d = await RealismTileCache.data(for: base.appendingPathComponent("tex_\(name)_em.png")), let img = UIImage(data: d) { m.emission.contents = img; m.emission.wrapS = .repeat; m.emission.wrapT = .repeat; m.emission.intensity = 0 }
            sharpen(m.diffuse); sharpen(m.emission)
            switch name {
            case "glass": m.metalness.contents = 0.85; m.roughness.contents = 0.12
            case "metal": m.metalness.contents = 0.6; m.roughness.contents = 0.5
            case "office": m.metalness.contents = 0.05; m.roughness.contents = 0.7
            default: m.metalness.contents = 0.0; m.roughness.contents = 0.9
            }
        case .trees:
            m.diffuse.contents = name == "trunk" ? ObjLoader.foliageSeason.trunkColor : ObjLoader.foliageSeason.leafColor
            m.roughness.contents = 1.0; m.metalness.contents = 0.0
        }
        cache[key] = m; return m
    }

    /// Ground/building photo textures otherwise look blurry once the camera gets close or views
    /// them at a grazing angle — SceneKit's default texture sampling has no mipmapping/anisotropy
    /// unless explicitly requested. Linear filtering across all three stages + high anisotropy
    /// keeps detail sharp at any distance or angle without any extra network/tile-baking cost.
    private static func sharpen(_ prop: SCNMaterialProperty) {
        prop.magnificationFilter = .linear
        prop.minificationFilter = .linear
        prop.mipFilter = .linear
        prop.maxAnisotropy = 16
    }

    static func node(from groups: [Group], style: ObjStyle, base: URL, tile: String, ground: GroundGrid?, cache: inout [String: SCNMaterial]) async -> SCNNode {
        let node = SCNNode()
        // merge groups per object name so a building/tree is one node that can be dropped onto terrain
        var byObject: [String: [Group]] = [:]; var order: [String] = []
        for g in groups { let key = g.name.split(separator: "_").first.map(String.init) ?? g.name; if byObject[key] == nil { order.append(key) }; byObject[key, default: []].append(g) }
        for key in order {
            let objNode = SCNNode(); objNode.name = key
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude, minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
            for g in byObject[key] ?? [] {
                let src = SCNGeometrySource(vertices: g.v)
                let tex = SCNGeometrySource(textureCoordinates: g.uv)
                let el = SCNGeometryElement(indices: g.idx, primitiveType: .triangles)
                let geo = SCNGeometry(sources: [src, tex], elements: [el])
                geo.firstMaterial = await material(for: g.material, style: style, base: base, tile: tile, cache: &cache)
                objNode.addChildNode(SCNNode(geometry: geo))
                for v in g.v { minX = min(minX, v.x); maxX = max(maxX, v.x); minZ = min(minZ, v.z); maxZ = max(maxZ, v.z) }
            }
            if let ground, style != .ortho, minX < maxX {
                objNode.position.y = Float(ground.height(x: Double((minX + maxX) / 2), y: Double(-(minZ + maxZ) / 2)))
            }
            node.addChildNode(objNode)
        }
        return node
    }

    /// Mesh tiles: named m_i_j, indices from west / from north.
    static func loadMeshTiles(base: URL, meta: TileMeta, around c: CLLocationCoordinate2D, style: ObjStyle) async -> SCNNode {
        let kx = 111320.0 * cos(meta.center[0] * .pi / 180), ky = 110540.0
        let x = (c.longitude - meta.center[1]) * kx, y = (c.latitude - meta.center[0]) * ky
        let i0 = Int(floor((x + meta.half) / meta.tileM)), j0 = Int(floor((meta.half - y) / meta.tileM))
        return await loadTiles(base: base, names: neighbours(i0, j0).map { "m_\($0.0)_\($0.1)" }, style: style, ground: nil)
    }
    /// Building/tree tiles: named <prefix>_i_j, indices = floor(x/tileM), floor(y/tileM) from the area centre.
    static func loadGridTiles(base: URL, prefix: String, meta: TileMeta, around c: CLLocationCoordinate2D, style: ObjStyle, ground: GroundGrid?) async -> SCNNode {
        let kx = 111320.0 * cos(meta.center[0] * .pi / 180), ky = 110540.0
        let x = (c.longitude - meta.center[1]) * kx, y = (c.latitude - meta.center[0]) * ky
        let i0 = Int(floor(x / meta.tileM)), j0 = Int(floor(y / meta.tileM))
        return await loadTiles(base: base, names: neighbours(i0, j0).map { "\(prefix)_\($0.0)_\($0.1)" }, style: style, ground: ground)
    }
    private static func neighbours(_ i: Int, _ j: Int) -> [(Int, Int)] { [(i, j), (i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1), (i - 1, j - 1), (i + 1, j - 1), (i - 1, j + 1), (i + 1, j + 1)] }

    static func loadTiles(base: URL, names: [String], style: ObjStyle, ground: GroundGrid?) async -> SCNNode {
        let parent = SCNNode(); var cache: [String: SCNMaterial] = [:]
        for name in names {
            guard let d = await RealismTileCache.data(for: base.appendingPathComponent("\(name).obj")), let text = String(data: d, encoding: .utf8) else { continue }
            let groups = parse(text)
            if groups.isEmpty { continue }
            let n = await node(from: groups, style: style, base: base, tile: name, ground: ground, cache: &cache)
            n.name = name; parent.addChildNode(n)
        }
        return parent
    }
}

// MARK: - Staging: physically-based sky, sun presets, camera

enum RealismStage {
    static func setup(_ sc: SCNScene, focus: SCNVector3, distance: Float) {
        let sun = SCNNode(); sun.name = "sun"; sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred; sun.light?.shadowRadius = 8; sun.light?.shadowSampleCount = 16; sun.light?.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.light?.automaticallyAdjustsShadowProjection = true; sun.light?.shadowColor = UIColor(white: 0, alpha: 0.6)
        sc.rootNode.addChildNode(sun)
        let amb = SCNNode(); amb.name = "amb"; amb.light = SCNLight(); amb.light?.type = .ambient; sc.rootNode.addChildNode(amb)
        let cam = SCNNode(); cam.name = "cam"; cam.camera = SCNCamera(); cam.camera?.zFar = 20000; cam.camera?.zNear = 0.5; cam.camera?.fieldOfView = 58
        cam.camera?.wantsHDR = true; cam.camera?.wantsExposureAdaptation = true; cam.camera?.bloomIntensity = 0.35; cam.camera?.bloomThreshold = 0.9
        cam.camera?.screenSpaceAmbientOcclusionIntensity = 1.2; cam.camera?.screenSpaceAmbientOcclusionRadius = 6
        cam.camera?.colorGrading.contents = nil
        cam.position = SCNVector3(focus.x + distance * 0.55, focus.y + distance * 0.55, focus.z + distance * 0.55); cam.look(at: focus)
        sc.rootNode.addChildNode(cam)
        let pivot = SCNNode(); pivot.name = "focus"; pivot.position = focus; sc.rootNode.addChildNode(pivot)
        // subtle fog for depth
        sc.fogStartDistance = 600; sc.fogEndDistance = 6000; sc.fogDensityExponent = 1.4
    }

    static func apply(_ preset: String, to sc: SCNScene, lat: Double, lon: Double, date: Date = Date()) {
        let sun = sc.rootNode.childNode(withName: "sun", recursively: false), amb = sc.rootNode.childNode(withName: "amb", recursively: false)
        let cam = sc.rootNode.childNode(withName: "cam", recursively: false)?.camera
        var elev: Float = 0.9, turb: Float = 0.25, sunI: CGFloat = 1500, ambI: CGFloat = 250, emis: CGFloat = 0, fog = UIColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1)
        var azDeg: Float = 200   // south-ish default; overridden below for "auto"
        var isNight = false
        switch preset {
        case "golden": elev = 0.12; turb = 0.55; sunI = 1900; ambI = 200; emis = 0.4; fog = UIColor(red: 0.95, green: 0.75, blue: 0.55, alpha: 1); azDeg = 281
        case "night": elev = -0.3; turb = 0.1; sunI = 60; ambI = 40; emis = 1.0; fog = UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1); isNight = true; azDeg = 206
        case "overcast": elev = 0.5; turb = 0.95; sunI = 600; ambI = 420; emis = 0.15; fog = UIColor(white: 0.75, alpha: 1); azDeg = 206
        case "auto":
            // real sun position for this place and moment — see Solar (Weather.swift) + Geo.bearing (Extras.swift)
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let elevDeg = Solar.sunElevation(at: coord, date: date)
            azDeg = Float(Geo.bearing(from: coord, to: Solar.subsolar(date)))
            elev = Float(sin(elevDeg * .pi / 180))
            switch elevDeg {
            case 20...: turb = 0.25; sunI = 1500; ambI = 250; emis = 0; fog = UIColor(red: 0.75, green: 0.82, blue: 0.92, alpha: 1)
            case 0..<20: let t = CGFloat(elevDeg / 20); turb = 0.55; sunI = 1500 + 400 * Double(t); ambI = 200; emis = 0.5 - 0.5 * t; fog = UIColor(red: 0.95, green: 0.75, blue: 0.55, alpha: 1)
            case -6..<0: turb = 0.7; sunI = 400; ambI = 150; emis = 0.75; fog = UIColor(red: 0.35, green: 0.28, blue: 0.32, alpha: 1)
            default: turb = 0.1; sunI = 60; ambI = 40; emis = 1.0; fog = UIColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1); isNight = true
            }
        default: break
        }
        // physically-based sky drives both the backdrop and image-based lighting (reflections in glass)
        let sky = MDLSkyCubeTexture(name: "sky", channelEncoding: .float16, textureDimensions: vector_int2(512, 512), turbidity: turb, sunElevation: max(elev, 0.02), upperAtmosphereScattering: 0.35, groundAlbedo: 0.3)
        sky.groundColor = CGColor(red: 0.2, green: 0.25, blue: 0.18, alpha: 1)
        sky.update()
        sc.background.contents = isNight ? UIColor(red: 0.01, green: 0.015, blue: 0.03, alpha: 1) : sky
        sc.lightingEnvironment.contents = sky; sc.lightingEnvironment.intensity = isNight ? 0.08 : preset == "overcast" ? 1.0 : 1.4
        sc.fogColor = fog
        // sun direction: real azimuth for "auto", a fixed look for the manual presets
        let az = azDeg * .pi / 180
        let e = max(elev, 0.05)
        let dir = SCNVector3(sin(az) * cos(e), -sin(e), -cos(az) * cos(e))
        sun?.look(at: SCNVector3(dir.x, dir.y, dir.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        sun?.light?.intensity = sunI; sun?.light?.temperature = preset == "golden" ? 3200 : isNight ? 8000 : 6000
        amb?.light?.intensity = ambI
        cam?.exposureOffset = isNight ? 0.6 : 0
        cam?.bloomIntensity = isNight ? 0.9 : 0.35
        // window lights — lit whenever it's actually dark out
        sc.rootNode.enumerateChildNodes { n, _ in
            for m in n.geometry?.materials ?? [] where m.emission.contents is UIImage { m.emission.intensity = emis * 1.6 }
        }
    }
}

struct RealismSCNView: UIViewRepresentable {
    let scene: SCNScene
    var onFocusMoved: ((SCNVector3) -> Void)? = nil
    var onViewReady: ((SCNView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onFocusMoved: onFocusMoved) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = scene
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.maximumVerticalAngle = 88; v.defaultCameraController.minimumVerticalAngle = 2
        if let f = scene.rootNode.childNode(withName: "focus", recursively: false) { v.defaultCameraController.target = f.position }
        v.pointOfView = scene.rootNode.childNode(withName: "cam", recursively: false)
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.backgroundColor = .black
        v.contentScaleFactor = UIScreen.main.scale   // full Retina resolution — no soft/blurry downsample
        v.delegate = context.coordinator
        context.coordinator.view = v
        let ready = onViewReady
        DispatchQueue.main.async { ready?(v) }
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) { context.coordinator.onFocusMoved = onFocusMoved }

    /// Polls the camera controller's pan/orbit target a few times a second while the view is
    /// open — this is how we know the user has panned somewhere new and it's time to stream
    /// in the next ring of tiles (moving the target is SceneKit's own two-finger-pan gesture,
    /// already enabled by `allowsCameraControl` above; no extra gesture code needed).
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var onFocusMoved: ((SCNVector3) -> Void)?
        weak var view: SCNView?
        private var lastCheck: TimeInterval = 0
        private var lastTarget: SCNVector3?

        init(onFocusMoved: ((SCNVector3) -> Void)?) { self.onFocusMoved = onFocusMoved }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard time - lastCheck > 0.35, let v = view else { return }
            lastCheck = time
            let t = v.defaultCameraController.target
            if let last = lastTarget {
                let d = sqrt(pow(t.x - last.x, 2) + pow(t.z - last.z, 2))
                if d < 2 { return }
            }
            lastTarget = t
            let cb = onFocusMoved
            DispatchQueue.main.async { cb?(t) }
        }
    }
}

// MARK: - Share sheet (photo mode export)

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
