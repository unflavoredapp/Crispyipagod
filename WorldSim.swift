import Foundation
import SceneKit
import UIKit

// MARK: - Season — real date + hemisphere, used to tint foliage

enum Season: String {
    case spring, summer, autumn, winter

    static func current(latitude: Double, date: Date = Date()) -> Season {
        let doy = Double(Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: date) ?? 180)
        let northern = latitude >= 0
        let d = northern ? doy : doy.truncatingRemainder(dividingBy: 365) + 182.5
        let wrapped = d.truncatingRemainder(dividingBy: 365)
        switch wrapped {
        case ..<60, 335...: return .winter
        case 60..<152: return .spring
        case 152..<244: return .summer
        default: return .autumn
        }
    }

    var leafColor: UIColor {
        switch self {
        case .spring: return UIColor(red: 0.40, green: 0.66, blue: 0.30, alpha: 1)
        case .summer: return UIColor(red: 0.22, green: 0.49, blue: 0.22, alpha: 1)
        case .autumn: return UIColor(red: 0.74, green: 0.43, blue: 0.14, alpha: 1)
        case .winter: return UIColor(white: 0.55, alpha: 1)   // bare-branch look
        }
    }
    var trunkColor: UIColor { UIColor(red: 0.37, green: 0.25, blue: 0.15, alpha: 1) }
}

// MARK: - Live weather (Open-Meteo — free, keyless, https) for the 3D scene

struct WeatherNow {
    let code: Int
    let precipitation: Double
    let cloudCover: Double
    var isRain: Bool { (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code) }
    var isSnow: Bool { (71...77).contains(code) || (85...86).contains(code) }
    var isFoggy: Bool { (45...48).contains(code) }
}

enum OpenMeteo {
    static func current(lat: Double, lon: Double) async -> WeatherNow? {
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=weathercode,precipitation,cloudcover") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let code = current["weathercode"] as? Int else { return nil }
        return WeatherNow(code: code, precipitation: current["precipitation"] as? Double ?? 0, cloudCover: current["cloudcover"] as? Double ?? 0)
    }
}

// MARK: - Rain/snow/fog particle effects, anchored around the focus point

enum WeatherFX {
    static func apply(_ weather: WeatherNow?, to scene: SCNScene, focus: SCNVector3) {
        scene.rootNode.childNode(withName: "weatherFX", recursively: false)?.removeFromParentNode()
        guard let weather else { return }
        let node = SCNNode(); node.name = "weatherFX"
        node.position = SCNVector3(focus.x, focus.y + 40, focus.z)

        if weather.isRain {
            let p = SCNParticleSystem()
            p.birthRate = 3500; p.particleLifeSpan = 1.6
            p.particleVelocity = 24; p.particleVelocityVariation = 4
            p.emitterShape = SCNBox(width: 140, height: 1, length: 140, chamferRadius: 0)
            p.particleSize = 0.04; p.particleColor = UIColor(white: 0.8, alpha: 0.55)
            p.acceleration = SCNVector3(0, -2, 0)
            p.isAffectedByGravity = false
            node.addParticleSystem(p)
        } else if weather.isSnow {
            let p = SCNParticleSystem()
            p.birthRate = 700; p.particleLifeSpan = 7
            p.particleVelocity = 3; p.particleVelocityVariation = 1.2
            p.emitterShape = SCNBox(width: 140, height: 1, length: 140, chamferRadius: 0)
            p.particleSize = 0.12; p.particleColor = .white
            p.acceleration = SCNVector3(0, -0.5, 0)
            p.spreadingAngle = 25
            node.addParticleSystem(p)
        }
        if weather.isFoggy {
            scene.fogStartDistance = 20; scene.fogEndDistance = 380; scene.fogDensityExponent = 1.0
        }
        scene.rootNode.addChildNode(node)
    }
}
