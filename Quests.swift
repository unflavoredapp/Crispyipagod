import Foundation

// MARK: - Quests — real, trackable objectives that tie into the XP system.
// (Named "Quest" to avoid colliding with the existing `Mission` layer-preset enum.)

struct Quest: Identifiable {
    let id: String
    let title: String
    let detail: String
    let target: Int
    let progress: Int
    let xp: Int
    var done: Bool { progress >= target }
}

extension AppState {
    private var ud2: UserDefaults { .standard }

    // MARK: Counters (plain UserDefaults — read on demand by `quests`)

    var questTracedCountries: Set<String> {
        get { Set(ud2.stringArray(forKey: "q_countries") ?? []) }
        set { ud2.set(Array(newValue), forKey: "q_countries") }
    }
    var questFireIDs: Set<String> {
        get { Set(ud2.stringArray(forKey: "q_fires") ?? []) }
        set { ud2.set(Array(newValue), forKey: "q_fires") }
    }
    var questBookmarkOffsets: Set<Int> {
        get { Set((ud2.array(forKey: "q_tzoffsets") as? [Int]) ?? []) }
        set { ud2.set(Array(newValue), forKey: "q_tzoffsets") }
    }
    var questTracesRun: Int {
        get { ud2.integer(forKey: "q_traces") }
        set { ud2.set(newValue, forKey: "q_traces") }
    }
    var questUFOsSighted: Int {
        get { ud2.integer(forKey: "q_ufos") }
        set { ud2.set(newValue, forKey: "q_ufos") }
    }
    var questPhotosTaken: Int {
        get { ud2.integer(forKey: "q_photos") }
        set { ud2.set(newValue, forKey: "q_photos") }
    }

    /// Every distinct realism tile ever streamed in, across every area you've visited.
    var discoveredTileKeys: Set<String> {
        get { Set(ud2.stringArray(forKey: "discoveredTiles") ?? []) }
        set { ud2.set(Array(newValue), forKey: "discoveredTiles") }
    }
    var discoveredTilesCount: Int { discoveredTileKeys.count }

    // MARK: Recorders — call these from the real actions that should count

    func recordTracedCountries(_ codes: [String]) {
        var set = questTracedCountries; let before = set.count
        for c in codes where !c.isEmpty { set.insert(c) }
        questTracedCountries = set
        if set.count > before { objectWillChange.send() }
        checkQuestCompletion()
    }
    func recordFireSpotted(_ id: String) {
        var set = questFireIDs; let before = set.count
        set.insert(id); questFireIDs = set
        if set.count > before { objectWillChange.send() }
        checkQuestCompletion()
    }
    func recordBookmarkTZ(lon: Double) {
        let offset = Int((lon / 15).rounded())
        var set = questBookmarkOffsets; let before = set.count
        set.insert(offset); questBookmarkOffsets = set
        if set.count > before { objectWillChange.send() }
        checkQuestCompletion()
    }
    func recordTraceRun() { questTracesRun += 1; checkQuestCompletion() }
    func recordUFOSighting() { questUFOsSighted += 1; checkQuestCompletion() }
    func recordPhotoTaken() { questPhotosTaken += 1; checkQuestCompletion() }
    func recordDiscoveredTiles(_ names: [String]) {
        guard !names.isEmpty else { return }
        var set = discoveredTileKeys; let before = set.count
        set.formUnion(names)
        discoveredTileKeys = set
        if set.count > before { objectWillChange.send() }
    }

    var quests: [Quest] {
        [
            Quest(id: "countries5", title: "Well-Traveled Packet", detail: "Trace a route through 5 different countries", target: 5, progress: min(5, questTracedCountries.count), xp: 40),
            Quest(id: "fires3", title: "Fire Watch", detail: "Spot 3 active wildfires", target: 3, progress: min(3, questFireIDs.count), xp: 30),
            Quest(id: "tz5", title: "Around the Clock", detail: "Bookmark locations in 5 different time zones", target: 5, progress: min(5, questBookmarkOffsets.count), xp: 30),
            Quest(id: "trace10", title: "Packet Hunter", detail: "Run 10 network traces", target: 10, progress: min(10, questTracesRun), xp: 25),
            Quest(id: "ufo1", title: "Believer", detail: "Witness a UFO sighting in the 3D world", target: 1, progress: min(1, questUFOsSighted), xp: 20),
            Quest(id: "photo5", title: "Shutterbug", detail: "Capture 5 photo-mode shots", target: 5, progress: min(5, questPhotosTaken), xp: 20),
        ]
    }

    private func checkQuestCompletion() {
        for q in quests where q.done {
            let key = "q_claimed_\(q.id)"
            guard !ud2.bool(forKey: key) else { continue }
            ud2.set(true, forKey: key)
            xp += q.xp
            show("QUEST COMPLETE · \(q.title) (+\(q.xp) XP)")
        }
    }

    // MARK: Daily streak

    var lastOpenDateStamp: String? {
        get { ud2.string(forKey: "lastOpenDate") }
        set { ud2.set(newValue, forKey: "lastOpenDate") }
    }
    var streakCount: Int {
        get { ud2.integer(forKey: "streakCount") }
        set { ud2.set(newValue, forKey: "streakCount") }
    }

    /// Call once when the app/globe view appears. Awards a small, growing XP bonus for
    /// consecutive daily opens; resets the streak if a day was missed.
    func checkDailyStreak() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        let today = df.string(from: Date())
        guard lastOpenDateStamp != today else { return }
        if let last = lastOpenDateStamp, let lastDate = df.date(from: last),
           Calendar.current.isDate(lastDate, inSameDayAs: Date().addingTimeInterval(-86400)) {
            streakCount += 1
        } else {
            streakCount = 1
        }
        lastOpenDateStamp = today
        let bonus = min(50, 5 * streakCount)
        xp += bonus
        show("DAILY STREAK · \(streakCount) day\(streakCount == 1 ? "" : "s") (+\(bonus) XP)")
    }
}
