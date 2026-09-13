import SwiftUI

// MARK: - Saved traces — replay a past trace instantly, no re-tracing needed

struct SavedTracesView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss
    let onSelect: (SavedTrace) -> Void

    var body: some View {
        NavigationStack {
            List {
                if s.savedTraces.isEmpty {
                    Text("No saved traces yet — run a trace, then tap the bookmark icon to keep it here.")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                } else {
                    ForEach(s.savedTraces) { t in
                        Button { onSelect(t) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.target).font(.system(size: 13, weight: .bold, design: .monospaced))
                                Text("\(t.hops.count) hops · \(t.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { s.deleteSavedTraces(at: $0) }
                }
            }
            .navigationTitle("Saved Traces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - Trace battle — race two hosts, shortest/fastest path wins

struct TraceBattleView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var hostA = ""
    @State private var hostB = ""
    @State private var hopsA: [NetHop] = []
    @State private var hopsB: [NetHop] = []
    @State private var running = false
    @State private var winner: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Contenders") {
                    TextField("Host or IP A", text: $hostA).font(.system(size: 13, design: .monospaced)).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    TextField("Host or IP B", text: $hostB).font(.system(size: 13, design: .monospaced)).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                }
                Section {
                    Button(running ? "Racing…" : "Start battle") { race() }
                        .disabled(running || hostA.trimmingCharacters(in: .whitespaces).isEmpty || hostB.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !hopsA.isEmpty || !hopsB.isEmpty {
                    Section("Results") {
                        resultRow(label: hostA, hops: hopsA, isWinner: winner == "A")
                        resultRow(label: hostB, hops: hopsB, isWinner: winner == "B")
                    }
                }
                if let winner {
                    Text(winner == "tie" ? "It's a tie!" : "\(winner == "A" ? hostA : hostB) wins — shorter real-world path.")
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                }
            }
            .navigationTitle("Trace Battle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    @ViewBuilder private func resultRow(label: String, hops: [NetHop], isWinner: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("\(hops.filter(\.responded).count) hops responded").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if isWinner { Image(systemName: "trophy.fill").foregroundStyle(.yellow) }
        }
    }

    private func race() {
        running = true; winner = nil; hopsA = []; hopsB = []
        Task {
            async let a: () = Traceroute.run(host: hostA) { hop in Task { @MainActor in hopsA.append(hop) } }
            async let b: () = Traceroute.run(host: hostB) { hop in Task { @MainActor in hopsB.append(hop) } }
            _ = await (a, b)
            await MainActor.run {
                running = false
                s.recordTraceRun(); s.recordTraceRun()
                let countA = hopsA.filter(\.responded).count
                let countB = hopsB.filter(\.responded).count
                if countA == 0 && countB == 0 { winner = "tie" }
                else if countB == 0 || (countA > 0 && countA < countB) { winner = "A" }
                else if countA == 0 || countB < countA { winner = "B" }
                else { winner = "tie" }
                if winner == "A" || winner == "B" { s.awardXP(.traceBattle) }
            }
        }
    }
}
