import SwiftUI

// MARK: - Operator progression ("user level") — XP earned by actually using the sim:
// scouting locations, saving intel, watching live traffic, running the 3D realism view.

struct LevelInfo {
    let level: Int
    let xpIntoLevel: Int
    let xpForNextLevel: Int
    var progress: Double { xpForNextLevel > 0 ? Double(xpIntoLevel) / Double(xpForNextLevel) : 1 }
}

enum XPEvent: String, CaseIterable {
    case viewLocation = "Scouted a location"
    case saveBookmark = "Saved intel (bookmark)"
    case openRealism = "Ran the 3D realism view"
    case openTimeline = "Reviewed the timeline"
    case toggleLayer = "Activated a new layer"
    case exploreNewTile = "Explored new terrain tiles"
    case trafficWatch = "Watched live traffic"

    var xp: Int {
        switch self {
        case .viewLocation: return 5
        case .saveBookmark: return 15
        case .openRealism: return 10
        case .openTimeline: return 8
        case .toggleLayer: return 6
        case .exploreNewTile: return 12
        case .trafficWatch: return 4
        }
    }
}

enum LevelSystem {
    /// Cumulative XP required to REACH a given level (level 1 = 0).
    static func xpRequired(for level: Int) -> Int {
        guard level > 1 else { return 0 }
        return 50 * (level - 1) * level
    }

    static func level(for totalXP: Int) -> Int {
        var lvl = 1
        while xpRequired(for: lvl + 1) <= totalXP { lvl += 1 }
        return lvl
    }

    static func info(for totalXP: Int) -> LevelInfo {
        let lvl = level(for: totalXP)
        let base = xpRequired(for: lvl)
        let next = xpRequired(for: lvl + 1)
        return LevelInfo(level: lvl, xpIntoLevel: totalXP - base, xpForNextLevel: max(1, next - base))
    }

    private static let titles: [Int: String] = [
        1: "Recruit Analyst", 3: "Field Observer", 5: "Signals Operator", 8: "Sector Watcher",
        12: "Senior Analyst", 16: "OSINT Specialist", 20: "Command Operator", 25: "Godseye Handler"
    ]

    static func title(for level: Int) -> String {
        var best = "Recruit Analyst"
        for (lvl, t) in titles.sorted(by: { $0.key < $1.key }) where level >= lvl { best = t }
        return best
    }
}

extension AppState {
    var levelInfo: LevelInfo { LevelSystem.info(for: xp) }

    /// Award XP for a real, in-app action. Shows a toast on level-up.
    func awardXP(_ event: XPEvent) {
        let before = LevelSystem.level(for: xp)
        xp += event.xp
        let after = LevelSystem.level(for: xp)
        if after > before {
            show("LEVEL UP · LV\(after) \(LevelSystem.title(for: after))")
        }
    }
}

// MARK: - HUD badge (drop into any top bar)

struct LevelBadge: View {
    @EnvironmentObject var s: AppState
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 12, weight: .bold))
                Text("LV\(s.levelInfo.level)").font(.system(size: 12, weight: .bold, design: .monospaced))
                XPBar(progress: s.levelInfo.progress).frame(width: 28, height: 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Capsule().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) { LevelDetailSheet() }
    }
}

struct XPBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.orange).frame(width: max(2, g.size.width * min(1, max(0, progress))))
            }
        }
        .clipShape(Capsule())
    }
}

struct LevelDetailSheet: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LV\(s.levelInfo.level) · \(LevelSystem.title(for: s.levelInfo.level))")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                        XPBar(progress: s.levelInfo.progress).frame(height: 8)
                        Text("\(s.levelInfo.xpIntoLevel) / \(s.levelInfo.xpForNextLevel) XP to next level")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Text("\(s.xp) total XP").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("How to earn XP") {
                    ForEach(XPEvent.allCases, id: \.rawValue) { e in
                        HStack {
                            Text(e.rawValue)
                            Spacer()
                            Text("+\(e.xp)").foregroundStyle(.orange).font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Operator Rank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
