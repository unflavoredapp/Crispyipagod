import SceneKit
import UIKit

// MARK: - Ambient traffic — cars & pedestrians patrolling the loaded realism ground.
// Agents are grounded to the real lidar/elevation data already loaded for the tile
// (GroundGrid), not a flat plane, so they follow the actual terrain contour.

final class TrafficSimulator {
    private(set) var root: SCNNode?

    typealias Bounds = (minX: Float, maxX: Float, minZ: Float, maxZ: Float)

    /// Populate cars + pedestrians across the loaded scene's ground footprint.
    /// `bounds` is the XZ bounding box (scene-local meters) of the terrain/building content already loaded.
    func populate(in scene: SCNScene, ground: GroundGrid?, bounds: Bounds, carCount: Int = 14, pedCount: Int = 22) {
        remove()
        guard bounds.maxX > bounds.minX, bounds.maxZ > bounds.minZ else { return }
        let r = SCNNode(); r.name = "traffic"
        scene.rootNode.addChildNode(r)
        root = r

        let carColors: [UIColor] = [.systemRed, .systemBlue, .systemYellow, .white, .darkGray, .systemGreen, .black]
        for i in 0..<carCount {
            let car = Self.makeCar(color: carColors[i % carColors.count])
            r.addChildNode(car)
            drivePatrol(car, ground: ground, bounds: bounds, speed: Float.random(in: 5.5...11))
        }
        for _ in 0..<pedCount {
            let ped = Self.makePedestrian()
            r.addChildNode(ped)
            walkPatrol(ped, ground: ground, bounds: bounds, speed: Float.random(in: 1.0...1.8))
        }
    }

    func remove() {
        root?.removeAllActions()
        root?.enumerateChildNodes { n, _ in n.removeAllActions() }
        root?.removeFromParentNode()
        root = nil
    }

    // MARK: Geometry (procedural low-poly, no bundled assets)

    private static func makeCar(color: UIColor) -> SCNNode {
        let node = SCNNode(); node.name = "car"
        let body = SCNBox(width: 1.8, height: 0.6, length: 4.0, chamferRadius: 0.15)
        body.firstMaterial?.diffuse.contents = color
        body.firstMaterial?.metalness.contents = 0.6
        body.firstMaterial?.roughness.contents = 0.35
        let bodyNode = SCNNode(geometry: body); bodyNode.position.y = 0.55
        node.addChildNode(bodyNode)
        let cabin = SCNBox(width: 1.4, height: 0.45, length: 2.0, chamferRadius: 0.1)
        cabin.firstMaterial?.diffuse.contents = UIColor(white: 0.08, alpha: 0.85)
        let cabinNode = SCNNode(geometry: cabin); cabinNode.position = SCNVector3(0, 0.9, -0.1)
        node.addChildNode(cabinNode)
        for dx: Float in [-0.95, 0.95] {
            for dz: Float in [-1.3, 1.3] {
                let wheel = SCNCylinder(radius: 0.32, height: 0.24)
                wheel.firstMaterial?.diffuse.contents = UIColor.black
                let wn = SCNNode(geometry: wheel)
                wn.eulerAngles.z = .pi / 2
                wn.position = SCNVector3(dx, 0.32, dz)
                node.addChildNode(wn)
            }
        }
        let headlight = SCNNode(geometry: SCNSphere(radius: 0.08))
        headlight.geometry?.firstMaterial?.emission.contents = UIColor.white
        headlight.position = SCNVector3(0, 0.55, 2.0)
        node.addChildNode(headlight)
        let taillight = SCNNode(geometry: SCNSphere(radius: 0.07))
        taillight.geometry?.firstMaterial?.emission.contents = UIColor.red
        taillight.position = SCNVector3(0, 0.55, -2.0)
        node.addChildNode(taillight)
        return node
    }

    private static func makePedestrian() -> SCNNode {
        let node = SCNNode(); node.name = "pedestrian"
        let shirtColors: [UIColor] = [.systemBlue, .systemRed, .darkGray, .systemOrange, .white, .systemPurple]
        let torso = SCNCapsule(capRadius: 0.22, height: 0.9)
        torso.firstMaterial?.diffuse.contents = shirtColors.randomElement()!
        let torsoNode = SCNNode(geometry: torso); torsoNode.position.y = 1.1
        node.addChildNode(torsoNode)
        let head = SCNSphere(radius: 0.16)
        head.firstMaterial?.diffuse.contents = UIColor(red: 0.85, green: 0.68, blue: 0.55, alpha: 1)
        let headNode = SCNNode(geometry: head); headNode.position.y = 1.72
        node.addChildNode(headNode)
        let legs = SCNCylinder(radius: 0.16, height: 0.85)
        legs.firstMaterial?.diffuse.contents = UIColor(white: 0.2, alpha: 1)
        let legsNode = SCNNode(geometry: legs); legsNode.position.y = 0.42
        node.addChildNode(legsNode)
        return node
    }

    // MARK: Movement — patrol a random polyline, looping back and forth forever

    private func drivePatrol(_ node: SCNNode, ground: GroundGrid?, bounds: Bounds, speed: Float) {
        let waypoints = Self.randomWaypoints(bounds: bounds, count: Int.random(in: 4...7), ground: ground)
        guard let first = waypoints.first else { return }
        node.position = first
        runPatrol(node, waypoints: waypoints, speed: speed)
    }

    private func walkPatrol(_ node: SCNNode, ground: GroundGrid?, bounds: Bounds, speed: Float) {
        // pedestrians wander a smaller local patch rather than crossing the whole map on foot
        let cx = Float.random(in: bounds.minX...bounds.maxX), cz = Float.random(in: bounds.minZ...bounds.maxZ)
        let local: Bounds = (max(bounds.minX, cx - 40), min(bounds.maxX, cx + 40), max(bounds.minZ, cz - 40), min(bounds.maxZ, cz + 40))
        let waypoints = Self.randomWaypoints(bounds: local, count: Int.random(in: 3...5), ground: ground)
        guard let first = waypoints.first else { return }
        node.position = first
        runPatrol(node, waypoints: waypoints, speed: speed)
    }

    private func runPatrol(_ node: SCNNode, waypoints: [SCNVector3], speed: Float) {
        guard waypoints.count > 1 else { return }
        let loop = waypoints + Array(waypoints.reversed().dropFirst().dropLast())
        var actions: [SCNAction] = []
        var prev = waypoints[0]
        let full = Array(loop.dropFirst()) + [waypoints[0]]
        for pt in full {
            let dx = pt.x - prev.x, dz = pt.z - prev.z
            let d = sqrt(dx * dx + dz * dz)
            if d < 0.05 { prev = pt; continue }
            let dur = TimeInterval(max(0.4, d / speed))
            let angle = CGFloat(atan2(Double(dx), Double(dz)))
            let turn = SCNAction.rotateTo(x: 0, y: angle, z: 0, duration: 0.3, usesShortestUnitArc: true)
            let move = SCNAction.move(to: pt, duration: dur)
            actions.append(SCNAction.group([turn, move]))
            prev = pt
        }
        guard !actions.isEmpty else { return }
        // small random phase offset so agents don't all move in lockstep
        let delay = SCNAction.wait(duration: Double.random(in: 0...2))
        node.runAction(SCNAction.sequence([delay, SCNAction.repeatForever(SCNAction.sequence(actions))]))
    }

    private static func randomWaypoints(bounds: Bounds, count: Int, ground: GroundGrid?) -> [SCNVector3] {
        guard bounds.maxX > bounds.minX, bounds.maxZ > bounds.minZ else { return [] }
        var pts: [SCNVector3] = []
        for _ in 0..<count {
            let x = Float.random(in: bounds.minX...bounds.maxX)
            let z = Float.random(in: bounds.minZ...bounds.maxZ)
            let y = Float(ground?.height(x: Double(x), y: Double(-z)) ?? 0) + 0.02
            pts.append(SCNVector3(x, y, z))
        }
        return pts
    }
}
