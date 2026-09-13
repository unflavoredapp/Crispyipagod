import SceneKit
import UIKit

// MARK: - UFO encounter — a rare, self-contained event: saucer descends, tractor-beams down,
// leaves a crop circle in the field, an alien wanders briefly, then it all clears out.

enum UFOEncounter {
    static func spawn(in scene: SCNScene, ground: GroundGrid?, bounds: TrafficSimulator.Bounds, onComplete: @escaping () -> Void) {
        guard bounds.maxX > bounds.minX, bounds.maxZ > bounds.minZ else { onComplete(); return }
        let x = Float.random(in: bounds.minX...bounds.maxX)
        let z = Float.random(in: bounds.minZ...bounds.maxZ)
        let groundY = Float(ground?.height(x: Double(x), y: Double(-z)) ?? 0)
        let hoverHeight: Float = 45

        let root = SCNNode(); root.name = "ufoEncounter"
        root.position = SCNVector3(x, groundY + hoverHeight + 220, z)
        scene.rootNode.addChildNode(root)

        let saucer = makeSaucer()
        root.addChildNode(saucer)

        let beam = makeBeam(height: hoverHeight)
        beam.position = SCNVector3(0, -hoverHeight / 2, 0)
        root.addChildNode(beam)

        let circle = makeCropCircle()
        circle.position = SCNVector3(x, groundY + 0.05, z)
        circle.opacity = 0
        scene.rootNode.addChildNode(circle)

        let alien = makeAlien()
        alien.position = SCNVector3(x + 3, groundY, z + 2)
        alien.opacity = 0
        scene.rootNode.addChildNode(alien)

        // saucer spins and bobs continuously while present
        let spin = SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6))
        let bob = SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 1.5, z: 0, duration: 2), SCNAction.moveBy(x: 0, y: -1.5, z: 0, duration: 2)
        ]))
        saucer.runAction(spin)
        saucer.runAction(bob)

        let descend = SCNAction.move(to: SCNVector3(x, groundY + hoverHeight, z), duration: 3)
        descend.timingMode = .easeOut
        let ascend = SCNAction.move(to: SCNVector3(x, groundY + hoverHeight + 220, z), duration: 3)
        ascend.timingMode = .easeIn
        root.runAction(SCNAction.sequence([descend, SCNAction.wait(duration: 14), ascend]))
        root.runAction(SCNAction.sequence([SCNAction.wait(duration: 20), SCNAction.fadeOut(duration: 1), SCNAction.removeFromParentNode()]))

        circle.runAction(SCNAction.sequence([SCNAction.wait(duration: 2), SCNAction.fadeIn(duration: 2)]))
        alien.runAction(SCNAction.sequence([SCNAction.wait(duration: 4), SCNAction.fadeIn(duration: 1.5)]))
        circle.runAction(SCNAction.sequence([SCNAction.wait(duration: 45), SCNAction.fadeOut(duration: 3), SCNAction.removeFromParentNode()]))
        alien.runAction(SCNAction.sequence([SCNAction.wait(duration: 20), SCNAction.fadeOut(duration: 2), SCNAction.removeFromParentNode()]))

        DispatchQueue.main.asyncAfter(deadline: .now() + 21) { onComplete() }
    }

    private static func makeSaucer() -> SCNNode {
        let node = SCNNode()
        let hull = SCNSphere(radius: 6)
        hull.firstMaterial?.diffuse.contents = UIColor(white: 0.75, alpha: 1)
        hull.firstMaterial?.metalness.contents = 0.9
        hull.firstMaterial?.roughness.contents = 0.2
        let hullNode = SCNNode(geometry: hull)
        hullNode.scale = SCNVector3(1, 0.28, 1)
        node.addChildNode(hullNode)

        let dome = SCNSphere(radius: 2.6)
        dome.firstMaterial?.diffuse.contents = UIColor(red: 0.4, green: 0.9, blue: 0.9, alpha: 0.55)
        dome.firstMaterial?.emission.contents = UIColor(red: 0.3, green: 0.8, blue: 0.8, alpha: 1)
        let domeNode = SCNNode(geometry: dome); domeNode.position.y = 1.0
        node.addChildNode(domeNode)

        for i in 0..<10 {
            let a = Float(i) / 10 * 2 * .pi
            let light = SCNNode(geometry: SCNSphere(radius: 0.3))
            light.geometry?.firstMaterial?.emission.contents = i % 2 == 0 ? UIColor.cyan : UIColor.systemPink
            light.position = SCNVector3(cos(a) * 5.6, 0, sin(a) * 5.6)
            node.addChildNode(light)
        }
        let glow = SCNLight(); glow.type = .omni; glow.intensity = 400; glow.color = UIColor.cyan
        let glowNode = SCNNode(); glowNode.light = glow
        node.addChildNode(glowNode)
        return node
    }

    private static func makeBeam(height: Float) -> SCNNode {
        let cone = SCNCone(topRadius: 0.4, bottomRadius: 5, height: CGFloat(height))
        cone.firstMaterial?.diffuse.contents = UIColor(red: 0.5, green: 1, blue: 0.9, alpha: 0.18)
        cone.firstMaterial?.emission.contents = UIColor(red: 0.4, green: 0.9, blue: 0.85, alpha: 1)
        cone.firstMaterial?.isDoubleSided = true
        cone.firstMaterial?.lightingModel = .constant
        cone.firstMaterial?.blendMode = .add
        return SCNNode(geometry: cone)
    }

    private static func makeCropCircle() -> SCNNode {
        let node = SCNNode()
        let ringRadii: [(CGFloat, CGFloat)] = [(0.5, 6), (6.5, 7), (8, 9.2)]
        for (inner, outer) in ringRadii {
            let ring = SCNGeometry.ringPlane(inner: inner, outer: outer)
            ring.firstMaterial?.diffuse.contents = UIColor(red: 0.55, green: 0.45, blue: 0.15, alpha: 0.9)
            ring.firstMaterial?.lightingModel = .constant
            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles.x = -.pi / 2
            node.addChildNode(ringNode)
        }
        return node
    }

    private static func makeAlien() -> SCNNode {
        let node = SCNNode()
        let green = UIColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 1)
        let body = SCNCapsule(capRadius: 0.22, height: 1.1)
        body.firstMaterial?.diffuse.contents = green
        let bodyNode = SCNNode(geometry: body); bodyNode.position.y = 0.7
        node.addChildNode(bodyNode)

        let head = SCNSphere(radius: 0.28)
        head.firstMaterial?.diffuse.contents = green
        let headNode = SCNNode(geometry: head); headNode.position.y = 1.5
        headNode.scale = SCNVector3(0.9, 1.2, 1.1)
        node.addChildNode(headNode)

        for dx: Float in [-0.18, 0.18] {
            let eye = SCNSphere(radius: 0.08)
            eye.firstMaterial?.diffuse.contents = UIColor.black
            let eyeNode = SCNNode(geometry: eye)
            eyeNode.position = SCNVector3(dx, 1.52, 0.22)
            node.addChildNode(eyeNode)
        }
        node.runAction(SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.rotateBy(x: 0, y: 0.6, z: 0, duration: 1.5),
            SCNAction.rotateBy(x: 0, y: -0.6, z: 0, duration: 1.5)
        ])))
        return node
    }
}

private extension SCNGeometry {
    /// A flat ring (annulus), used to build the concentric crop-circle rings.
    static func ringPlane(inner: CGFloat, outer: CGFloat, segments: Int = 48) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            vertices.append(SCNVector3(cos(a) * Float(outer), sin(a) * Float(outer), 0))
            vertices.append(SCNVector3(cos(a) * Float(inner), sin(a) * Float(inner), 0))
        }
        for i in 0..<segments {
            let o0 = Int32(i * 2), i0 = Int32(i * 2 + 1), o1 = Int32(i * 2 + 2), i1 = Int32(i * 2 + 3)
            indices.append(contentsOf: [o0, i0, o1, i0, i1, o1])
        }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [source], elements: [element])
    }
}
