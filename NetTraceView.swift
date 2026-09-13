import SwiftUI
import MapKit

// MARK: - Net Trace — real ICMP traceroute plotted on the globe, with a WHOIS/RDAP panel per hop

struct NetTraceView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var target: String = ""
    @State private var hops: [NetHop] = []
    @State private var running = false
    @State private var errorText: String?
    @State private var selectedHop: NetHop?
    @State private var rdap: RDAPRecord?
    @State private var rdapLoading = false
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 10), span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 140)))
    @State private var showBattle = false
    @State private var showSaved = false

    private let dotColors: [Color] = [.green, .cyan, .orange, .purple, .pink, .yellow, .mint, .indigo]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Map(position: $camera, interactionModes: .all) {
                let path = hops.compactMap(\.coord)
                if path.count > 1 {
                    MapPolyline(coordinates: path)
                        .stroke(Color.cyan.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, dash: [1]))
                }
                ForEach(Array(hops.enumerated()), id: \.element.id) { i, h in
                    if let c = h.coord {
                        Annotation(h.city ?? h.ip ?? "", coordinate: c, anchor: .center) {
                            Circle()
                                .fill(dotColors[i % dotColors.count])
                                .frame(width: selectedHop?.id == h.id ? 14 : 9, height: selectedHop?.id == h.id ? 14 : 9)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .onTapGesture { select(h) }
                        }
                    }
                }
            }
            .mapStyle(.imagery(elevation: .flat))
            .ignoresSafeArea()
            .preferredColorScheme(.dark)

            VStack(alignment: .leading, spacing: 8) {
                header
                targetBar
                if !hops.isEmpty { hopList }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: 300, alignment: .leading)

            if let hop = selectedHop {
                HStack {
                    Spacer()
                    RDAPPanel(hop: hop, record: rdap, loading: rdapLoading) { selectedHop = nil; rdap = nil }
                        .frame(maxWidth: 340)
                        .padding(.trailing, 12)
                        .padding(.top, 12)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 32, height: 32).background(Circle().fill(.ultraThinMaterial)) }
            Text("NET TRACE").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button { showSaved = true } label: { Image(systemName: "bookmark.fill").font(.system(size: 12)).frame(width: 30, height: 30).background(Circle().fill(.ultraThinMaterial)) }
            Button { showBattle = true } label: { Image(systemName: "flag.2.crossed.fill").font(.system(size: 12)).frame(width: 30, height: 30).background(Circle().fill(.ultraThinMaterial)) }
        }
        .sheet(isPresented: $showBattle) { TraceBattleView().environmentObject(s) }
        .sheet(isPresented: $showSaved) {
            SavedTracesView { saved in
                target = saved.target; hops = saved.hops; selectedHop = nil; rdap = nil
                if let last = hops.last(where: { $0.coord != nil })?.coord {
                    camera = .region(MKCoordinateRegion(center: last, span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)))
                }
                showSaved = false
            }
            .environmentObject(s)
        }
    }

    private var targetBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("hostname or IP", text: $target)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4)))
                Button { start() } label: {
                    Image(systemName: running ? "hourglass" : "play.fill")
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.green))
                        .foregroundStyle(.black)
                }
                .disabled(running || target.trimmingCharacters(in: .whitespaces).isEmpty)
                if !hops.isEmpty && !running {
                    Button { s.saveTrace(target: target, hops: hops) } label: {
                        Image(systemName: "bookmark").frame(width: 34, height: 34).background(Circle().fill(.ultraThinMaterial))
                    }
                }
            }
            if let errorText {
                Text(errorText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var hopList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hops.enumerated()), id: \.element.id) { i, h in
                    Button { select(h) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(h.responded ? dotColors[i % dotColors.count] : .gray.opacity(0.4)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.responded ? (h.city ?? h.ip ?? "hop \(h.ttl)") : "hop \(h.ttl) · no response")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                                if h.responded {
                                    Text([h.asn, h.isp].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if let rtt = h.rttMs {
                                Text(String(format: "%.1f ms", rtt))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                            if h.responded { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if i < hops.count - 1 { Divider().background(Color.white.opacity(0.08)) }
                }
            }
        }
        .frame(maxHeight: 320)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    // MARK: Actions

    private func select(_ h: NetHop) {
        guard h.responded else { return }
        selectedHop = h
        rdap = nil
        guard let ip = h.ip else { return }
        rdapLoading = true
        Task {
            let rec = await RDAPClient.lookup(ip: ip)
            await MainActor.run { rdap = rec; rdapLoading = false }
        }
    }

    private func start() {
        let host = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        running = true
        errorText = nil
        hops = []
        selectedHop = nil
        rdap = nil

        Task {
            await Traceroute.run(host: host) { hop in
                Task { @MainActor in hops.append(hop) }
            }
            await MainActor.run {
                running = false
                if hops.allSatisfy({ !$0.responded }) {
                    errorText = "No responses — the target may be blocking ICMP, or this network blocks outbound ICMP."
                }
            }
            await enrich()
            await MainActor.run {
                if let last = hops.last(where: { $0.coord != nil })?.coord {
                    camera = .region(MKCoordinateRegion(center: last, span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)))
                }
                s.awardXP(.runTrace)
                s.recordTraceRun()
                s.recordTracedCountries(hops.compactMap(\.countryCode))
            }
        }
    }

    private func enrich() async {
        let targets = hops.enumerated().compactMap { i, h -> (Int, String)? in h.ip.map { (i, $0) } }
        await withTaskGroup(of: (Int, GeoIP.Info?).self) { group in
            for (i, ip) in targets {
                group.addTask { (i, await GeoIP.lookup(ip: ip)) }
            }
            for await (i, info) in group {
                guard let info else { continue }
                await MainActor.run {
                    guard i < hops.count else { return }
                    hops[i].city = info.city
                    hops[i].country = info.country
                    hops[i].countryCode = info.countryCode
                    hops[i].lat = info.lat
                    hops[i].lon = info.lon
                    hops[i].asn = info.asn
                    hops[i].isp = info.isp
                }
            }
        }
    }
}

// MARK: - RDAP whois panel

private struct RDAPPanel: View {
    let hop: NetHop
    let record: RDAPRecord?
    let loading: Bool
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(hop.ip ?? "").font(.system(size: 14, weight: .bold, design: .monospaced))
                    Spacer()
                    Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                }
                if let asn = hop.asn {
                    Text("\(asn) · \(hop.isp ?? "")").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Divider().background(Color.white.opacity(0.1))

                if loading {
                    HStack { ProgressView().tint(.white); Text("Looking up RDAP…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                } else if let r = record {
                    Text("WHOIS / REGISTRATION (RDAP)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.cyan)
                    row("Name", r.name)
                    row("Handle", r.handle)
                    row("IP range", r.ipRange)
                    row("CIDR", r.cidr)
                    row("Type", r.type)
                    row("Country", r.country)
                    row("Registered", r.registered)
                    row("Last changed", r.lastChanged)
                    if !r.entities.isEmpty {
                        Divider().background(Color.white.opacity(0.1))
                        ForEach(r.entities) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.role.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.orange)
                                Text(e.name).font(.system(size: 11, design: .monospaced))
                                if let a = e.address { Text(a).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } else {
                    Text("No RDAP record found for this address.").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text(value).font(.system(size: 11, design: .monospaced))
                Spacer()
            }
        }
    }
}
