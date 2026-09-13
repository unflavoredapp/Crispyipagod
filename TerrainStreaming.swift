import SceneKit
import CoreLocation

/// Streams mesh/building/tree tiles in and out around the focus point as the user pans
/// through the realism view. Only a small ring of tiles is ever resident — as you cross a
/// tile boundary the next ring streams in (from the on-disk cache when possible, see
/// RealismTileCache) and the tiles that fell out of range are dropped, so memory and draw
/// calls stay bounded no matter how far you roam.
final class TerrainStreamer {
    struct Source { let prefix: String; let base: URL; let meta: TileMeta; let style: ObjStyle }

    private var sources: [String: Source] = [:]            // kind -> source ("mesh" / "buildings" / "trees")
    private var loadedTiles: [String: Set<String>] = [:]    // kind -> currently-resident tile names
    private var lastIndex: [String: (Int, Int)] = [:]       // kind -> last tile index we streamed around
    private var pendingKinds: Set<String> = []              // kinds with a stream in flight
    private weak var root: SCNNode?
    private var ground: GroundGrid?

    func configure(root: SCNNode, ground: GroundGrid?) {
        self.root = root
        self.ground = ground
    }

    func register(kind: String, prefix: String, base: URL, meta: TileMeta, style: ObjStyle, initiallyLoaded: [String], initialIndex: (Int, Int)) {
        sources[kind] = Source(prefix: prefix, base: base, meta: meta, style: style)
        loadedTiles[kind] = Set(initiallyLoaded)
        lastIndex[kind] = initialIndex
    }

    /// `focal` is the scene-local point the camera is currently orbiting/panning around.
    /// `origin` is the lat/lon the scene's local coordinate system is built relative to.
    func ensureLoaded(focal: SCNVector3, origin: (lat: Double, lon: Double)) {
        guard let root else { return }
        let kx = 111320.0 * cos(origin.lat * .pi / 180), ky = 110540.0
        let lon = origin.lon + Double(focal.x) / kx
        let lat = origin.lat - Double(focal.z) / ky

        for (kind, src) in sources where !pendingKinds.contains(kind) {
            let mkx = 111320.0 * cos(src.meta.center[0] * .pi / 180), mky = 110540.0
            let x = (lon - src.meta.center[1]) * mkx
            let y = (lat - src.meta.center[0]) * mky
            let i0: Int, j0: Int
            if kind == "mesh" {
                i0 = Int(floor((x + src.meta.half) / src.meta.tileM))
                j0 = Int(floor((src.meta.half - y) / src.meta.tileM))
            } else {
                i0 = Int(floor(x / src.meta.tileM))
                j0 = Int(floor(y / src.meta.tileM))
            }
            if lastIndex[kind]?.0 == i0, lastIndex[kind]?.1 == j0 { continue }
            lastIndex[kind] = (i0, j0)
            stream(kind: kind, src: src, i0: i0, j0: j0, root: root)
        }
    }

    private func stream(kind: String, src: Source, i0: Int, j0: Int, root: SCNNode) {
        let ring = [(i0, j0), (i0 - 1, j0), (i0 + 1, j0), (i0, j0 - 1), (i0, j0 + 1),
                    (i0 - 1, j0 - 1), (i0 + 1, j0 - 1), (i0 - 1, j0 + 1), (i0 + 1, j0 + 1)]
        let needed = Set(ring.map { "\(src.prefix)_\($0.0)_\($0.1)" })
        let have = loadedTiles[kind] ?? []
        let toLoad = Array(needed.subtracting(have))
        let toUnload = have.subtracting(needed)

        for name in toUnload {
            root.childNode(withName: name, recursively: false)?.removeFromParentNode()
        }
        loadedTiles[kind, default: []].subtract(toUnload)
        guard !toLoad.isEmpty else { return }

        pendingKinds.insert(kind)
        let ground = self.ground
        Task {
            let node = await ObjLoader.loadTiles(base: src.base, names: toLoad, style: src.style, ground: ground)
            await MainActor.run {
                for child in Array(node.childNodes) { root.addChildNode(child) }
                self.loadedTiles[kind, default: []].formUnion(toLoad)
                self.pendingKinds.remove(kind)
            }
        }
    }
}
