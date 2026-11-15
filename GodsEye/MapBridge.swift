import SwiftUI
import MapKit
import UIKit

// MARK: - Public API

/// iOS 16-compatible MapKit bridge replacing SwiftUI `Map` / `MapCameraPosition` / `MapReader` (iOS 17+).
struct GodsEyeMapView: UIViewRepresentable {
    @ObservedObject var s: AppState
    @ObservedObject private var radar: RadarEngine
    var onCameraChange: (CLLocationCoordinate2D, Double, Double, Double) -> Void
    var onTap: (CLLocationCoordinate2D) -> Void

    init(
        s: AppState,
        onCameraChange: @escaping (CLLocationCoordinate2D, Double, Double, Double) -> Void,
        onTap: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        self.s = s
        self._radar = ObservedObject(wrappedValue: s.radar)
        self.onCameraChange = onCameraChange
        self.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.showsCompass = true
        map.showsTraffic = s.showsTraffic
        map.mapType = s.mkMapType
        map.showsUserLocation = s.location.coordinate != nil
        map.camera = MKMapCamera(
            lookingAtCenter: s.center,
            fromDistance: max(s.distance, 200),
            pitch: CGFloat(min(max(s.pitch, 0), 80)),
            heading: s.heading
        )
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        context.coordinator.mapView = map
        context.coordinator.lastEpoch = s.cameraEpoch
        context.coordinator.rebuild(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        map.showsTraffic = s.showsTraffic
        if map.mapType != s.mkMapType { map.mapType = s.mkMapType }
        map.showsUserLocation = s.location.coordinate != nil

        if s.cameraEpoch != c.lastEpoch || (s.isProgrammaticCamera && !c.applyingProgrammatic) {
            c.lastEpoch = s.cameraEpoch
            c.applyingProgrammatic = true
            let cam = MKMapCamera(
                lookingAtCenter: s.center,
                fromDistance: max(s.distance, 200),
                pitch: CGFloat(min(max(s.pitch, 0), 80)),
                heading: s.heading
            )
            map.setCamera(cam, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { c.applyingProgrammatic = false }
        }
        c.rebuild(map)
        let w = Double(map.bounds.width > 0 ? map.bounds.width : UIScreen.main.bounds.width)
        if abs(s.viewWidth - w) > 1 { s.viewWidth = w }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: GodsEyeMapView
        weak var mapView: MKMapView?
        var lastEpoch: UInt64 = 0
        var applyingProgrammatic = false
        private var lastSignature = ""
        private var ownedOverlays: [MKOverlay] = []
        private var ownedAnnotations: [GEAnnotation] = []

        init(parent: GodsEyeMapView) { self.parent = parent }

        private var s: AppState { parent.s }

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let map = mapView, gr.state == .ended else { return }
            let pt = gr.location(in: map)
            var v: UIView? = map.hitTest(pt, with: nil)
            while let cur = v {
                if cur is MKAnnotationView { return }
                v = cur.superview
            }
            parent.onTap(map.convert(pt, toCoordinateFrom: map))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var v: UIView? = touch.view
            while let cur = v {
                if cur is MKAnnotationView { return false }
                v = cur.superview
            }
            return true
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !applyingProgrammatic, !s.isProgrammaticCamera else { return }
            let cam = mapView.camera
            parent.onCameraChange(cam.centerCoordinate, cam.centerCoordinateDistance, cam.heading, Double(cam.pitch))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let ground = overlay as? MKGroundOverlay {
                return MKGroundOverlayRenderer(groundOverlay: ground)
            }
            if let poly = overlay as? GEPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = poly.strokeColor
                r.lineWidth = poly.lineWidth
                r.lineDashPattern = poly.dash
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let gon = overlay as? GEPolygon {
                let r = MKPolygonRenderer(polygon: gon)
                r.fillColor = gon.fillColor
                r.strokeColor = gon.strokeColor
                r.lineWidth = gon.lineWidth
                r.lineDashPattern = gon.dash
                return r
            }
            if let circle = overlay as? GECircle {
                let r = MKCircleRenderer(circle: circle)
                r.fillColor = circle.fillColor
                r.strokeColor = circle.strokeColor
                r.lineWidth = circle.lineWidth
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let ge = annotation as? GEAnnotation else { return nil }
            let id = ge.reuseId
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? GEHostingAnnotationView)
                ?? GEHostingAnnotationView(annotation: ge, reuseIdentifier: id)
            view.configure(ge)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let ge = view.annotation as? GEAnnotation {
                ge.onSelect()
            }
            mapView.deselectAnnotation(view.annotation, animated: false)
        }

        // MARK: Rebuild

        func rebuild(_ map: MKMapView) {
            let sig = signature()
            guard sig != lastSignature else { return }
            lastSignature = sig

            map.removeOverlays(ownedOverlays)
            map.removeAnnotations(ownedAnnotations)
            ownedOverlays.removeAll(keepingCapacity: true)
            ownedAnnotations.removeAll(keepingCapacity: true)

            var overlays: [MKOverlay] = []
            var annotations: [GEAnnotation] = []
            buildContent(overlays: &overlays, annotations: &annotations)
            ownedOverlays = overlays
            ownedAnnotations = annotations
            map.addOverlays(overlays, level: .aboveRoads)
            map.addAnnotations(annotations)
        }

        private func signature() -> String {
            let s = self.s
            let distBucket = Int(s.distance / 50_000)
            return [
                s.layers.map(\.rawValue).sorted().joined(separator: ","),
                "\(distBucket)",
                "\(s.trail.count)|\(s.satTrack.count)|\(s.traceHistory.count)",
                "\(s.visibleContacts.count)|\(s.visibleShips.count)|\(s.visibleSatellites.count)",
                "\(s.visibleFires.count)|\(s.visibleCameras.count)|\(s.visibleQuakes.count)",
                "\(s.visibleLaunches.count)|\(s.visibleHazards.count)|\(s.visibleStations.count)",
                "\(s.storms.count)|\(s.visibleBikes.count)|\(s.visibleRadio.count)",
                "\(s.infra.count)|\(s.powerLines.count)|\(s.railLines.count)|\(s.railStations.count)",
                "\(s.visibleTrains.count)|\(s.scanners.count)|\(s.peaks.count)",
                "\(s.airportFeatures.count)|\(s.residential.count)|\(s.visibleCables.count)",
                "\(s.propertyLines.count)|\(s.regions.count)|\(s.annotations.count)",
                "\(s.trackedID ?? "")|\(s.wakes)|\(s.viewsheds)|\(s.showLabels)|\(s.detection)",
                "\(s.measureLine.count)|\(Int(s.replayT))|\(s.replay != nil)",
                "\(s.radar.composite?.frame.id ?? "-")|\(s.radar.satComposite?.frame.id ?? "-")",
                "\(s.radarOpacity)|\(s.night.count)|\(s.auroraPoints.count)|\(s.winds.count)",
                "\(s.cctv.watching.count)|\(s.radio.current?.id ?? "")|\(s.scannerNow?.id ?? "")",
                s.mapStyleRaw,
                s.accentRaw,
                s.trackedCoord.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) } ?? "-"
            ].joined(separator: "#")
        }

        // MARK: Content (parity with GlobeView mcTracks…mcUser)

        private func buildContent(overlays: inout [MKOverlay], annotations: inout [GEAnnotation]) {
            let s = self.s
            let accent = geUIColor(s.accent)

            // Trails
            if s.trail.count > 1 {
                overlays.append(GEPolyline(s.trail, stroke: geUIColor(s.trackedEntity?.kind.color ?? s.accent), width: 2.5))
            }
            if s.satTrack.count > 1 {
                overlays.append(GEPolyline(s.satTrack, stroke: UIColor.cyan.withAlphaComponent(0.55), width: 1.5, dash: [6, 6]))
            }
            if s.traceHistory.count > 1 {
                overlays.append(GEPolyline(s.traceHistory, stroke: UIColor.orange.withAlphaComponent(0.6), width: 1.5))
            }

            if let tc = s.trackedCoord, let te = s.trackedEntity, te.kind == .aircraft || te.kind == .military {
                annotations.append(GEAnnotation(id: "tracked-scope", coord: tc, reuse: "scope") {
                    Image(systemName: "scope").font(.system(size: 30, weight: .thin)).foregroundStyle(te.kind.color)
                } onSelect: {})
            }

            if s.wakes, s.distance < 800_000 {
                for c in s.visibleContacts {
                    if let gs = c.groundSpeedKt, gs > 40 {
                        let pts = [c.coord, c.coord.moved(meters: -gs * 0.514 * 90, bearing: c.track)]
                        overlays.append(GEPolyline(pts, stroke: (c.military ? UIColor.orange : accent).withAlphaComponent(0.45), width: 1.5))
                    }
                }
                for v in s.visibleShips where v.sogKt > 1 {
                    let pts = [v.coord, v.coord.moved(meters: -v.sogKt * 0.514 * 600, bearing: v.cog)]
                    overlays.append(GEPolyline(pts, stroke: UIColor.blue.withAlphaComponent(0.45), width: 1.5))
                }
            }

            for f in s.visibleFires {
                let size = min(4 + f.frp / 8, 16)
                annotations.append(GEAnnotation(id: "fire-\(f.id)", coord: f.coord, reuse: "fire") {
                    Circle().fill(Entity.Kind.fire.color.opacity(0.75))
                        .frame(width: size, height: size)
                        .frame(width: 20, height: 20)
                } onSelect: { s.select(Entity.from(f)) })
            }

            if s.measureLine.count > 1 {
                overlays.append(GEPolyline(s.measureLine, stroke: .white, width: 2, dash: [8, 6]))
            }
            if let a = s.measureA {
                annotations.append(GEAnnotation(id: "measure-a", coord: a, reuse: "ma") {
                    Image(systemName: "a.circle.fill").font(.title3).foregroundStyle(.white)
                } onSelect: {})
            }
            if let b = s.measureB, let a = s.measureA {
                annotations.append(GEAnnotation(id: "measure-b", coord: b, reuse: "mb") {
                    Image(systemName: "b.circle.fill").font(.title3).foregroundStyle(.white)
                } onSelect: {})
                let mid = Geo.greatCircle(a, b, points: 2)[1]
                let km = a.distance(to: b) / 1000
                annotations.append(GEAnnotation(id: "measure-d", coord: mid, reuse: "md") {
                    Text(String(format: "%.1f km", km))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                        .foregroundStyle(.white)
                } onSelect: {})
            }

            if let r = s.replay {
                let st = r.state(at: s.replayT)
                overlays.append(GEPolyline(r.track(upTo: s.replayT), stroke: .systemPink, width: 3))
                overlays.append(GEPolyline(r.track(upTo: LaunchReplay.duration), stroke: UIColor.systemPink.withAlphaComponent(0.25), width: 1, dash: [4, 6]))
                annotations.append(GEAnnotation(id: "replay", coord: st.coord, reuse: "replay") {
                    VStack(spacing: 2) {
                        Image(systemName: "paperplane.fill").rotationEffect(.degrees(r.azimuth - 45)).foregroundStyle(.pink).font(.title3)
                        Text("\(st.phase) · \(Int(st.altKm)) km").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4).background(Color.black.opacity(0.7))
                            .foregroundStyle(.white)
                    }
                } onSelect: {})
            }

            // Aircraft
            if s.layers.contains(.flights) || s.layers.contains(.military) {
                let showLabels = s.showLabels && s.distance < 250_000
                for c in s.visibleContacts {
                    annotations.append(GEAnnotation(id: "ac-\(c.id)", coord: c.coord, title: showLabels ? c.displayName : nil, reuse: "ac") {
                        MarkerGlyph(system: c.glyph,
                                    color: c.military ? .orange : s.accent,
                                    size: c.aircraftClass == .heavy ? 15 : 11,
                                    rotation: c.glyph == "airplane" ? c.track - 90 : (c.glyph == "paperplane.fill" ? c.track - 45 : c.track),
                                    id: c.id.uppercased(),
                                    tracked: s.trackedID == "ac-\(c.id)",
                                    detection: s.detection)
                    } onSelect: { s.select(Entity.from(c)) })
                }
            }

            for v in s.visibleShips {
                let show = s.showLabels && s.distance < 120_000
                annotations.append(GEAnnotation(id: "sh-\(v.id)", coord: v.coord, title: show ? v.displayName : nil, reuse: "ship") {
                    MarkerGlyph(system: "arrowtriangle.up.fill", color: .blue, size: 11,
                                rotation: v.cog, id: v.id, tracked: s.trackedID == "sh-\(v.id)", detection: s.detection)
                } onSelect: { s.select(Entity.from(v)) })
            }

            for sat in s.visibleSatellites {
                let show = s.showLabels && (sat.cls == .station || s.distance < 4_000_000)
                annotations.append(GEAnnotation(id: "sat-\(sat.id)", coord: sat.coord, title: show ? sat.name : nil, reuse: "sat") {
                    ZStack {
                        if sat.cls == .station {
                            Circle().stroke(Color.cyan.opacity(0.5), lineWidth: 1).frame(width: 30, height: 30)
                        }
                        Image(systemName: sat.cls == .station ? "sparkle" : "circle.fill")
                            .font(.system(size: sat.cls == .station ? 14 : 5, weight: .bold))
                            .foregroundStyle(sat.cls.color)
                    }
                    .frame(width: 30, height: 30)
                    .overlay { if s.detection { DetectionBox(id: sat.id, color: sat.cls.color) } }
                } onSelect: { s.select(Entity.from(sat)) })
            }

            if s.layers.contains(.airport) {
                for f in s.airportFeatures {
                    switch f.kind {
                    case .runway: overlays.append(GEPolyline(f.points, stroke: UIColor.white.withAlphaComponent(0.85), width: 5))
                    case .taxiway: overlays.append(GEPolyline(f.points, stroke: UIColor.yellow.withAlphaComponent(0.7), width: 2))
                    case .apron: overlays.append(GEPolygon(f.points, fill: UIColor.gray.withAlphaComponent(0.18), stroke: UIColor.gray.withAlphaComponent(0.5), width: 1))
                    case .terminal: overlays.append(GEPolygon(f.points, fill: UIColor.cyan.withAlphaComponent(0.15), stroke: UIColor.cyan.withAlphaComponent(0.6), width: 1))
                    }
                }
            }

            for cable in s.visibleCables {
                let col = geUIColor(Color(hex: cable.color)).withAlphaComponent(0.8)
                for seg in cable.segments {
                    overlays.append(GEPolyline(seg, stroke: col, width: 1.5))
                }
            }

            for a in s.visibleAirports {
                let show = s.showLabels && (a.type == "large_airport" || s.distance < 800_000)
                let label = a.iata.isEmpty ? a.id : a.iata
                annotations.append(GEAnnotation(id: "apt-\(a.id)", coord: a.coord, title: show ? label : nil, reuse: "apt") {
                    Image(systemName: "airplane.circle")
                        .font(.system(size: a.type == "large_airport" ? 14 : 10))
                        .foregroundStyle(Entity.Kind.airport.color)
                        .frame(width: 24, height: 24)
                } onSelect: { s.select(Entity.from(a)) })
            }

            for cam in s.visibleCameras {
                annotations.append(GEAnnotation(id: "cam-\(cam.id)", coord: cam.coord, reuse: "cam") {
                    ZStack {
                        Circle().fill(Color.purple.opacity(0.25)).frame(width: 22, height: 22)
                        if s.cctv.watching.contains(cam.id) { Circle().stroke(Color.red, lineWidth: 1.5).frame(width: 22, height: 22) }
                        Image(systemName: cam.isLiveVideo ? "video.fill" : "video").font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
                    }
                    .frame(width: 26, height: 26)
                } onSelect: { s.select(Entity.from(cam)) })
            }

            for a in s.annotations {
                annotations.append(GEAnnotation(id: "ann-\(a.id.uuidString)", coord: a.coord, reuse: "ann") {
                    VStack(spacing: 2) {
                        Text(a.label)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(s.accent))
                            .foregroundStyle(.black)
                        Image(systemName: "mappin").foregroundStyle(s.accent)
                    }
                } onSelect: {})
            }

            for poly in s.propertyLines {
                for ring in poly.rings {
                    if poly.kind == .building {
                        overlays.append(GEPolygon(ring, fill: UIColor.cyan.withAlphaComponent(0.10), stroke: UIColor.cyan.withAlphaComponent(0.9), width: 1.5, dash: [3, 3]))
                    } else {
                        let fill = poly.isTarget ? UIColor.yellow.withAlphaComponent(0.18) : UIColor.clear
                        let stroke = poly.isTarget ? UIColor.yellow : UIColor.yellow.withAlphaComponent(0.55)
                        overlays.append(GEPolygon(ring, fill: fill, stroke: stroke, width: poly.isTarget ? 2.5 : 1))
                    }
                }
            }

            if s.layers.contains(.residential), s.distance < 6_000 {
                for b in s.residential {
                    overlays.append(GEPolygon(b.points, fill: geUIColor(b.kind.fill), stroke: geUIColor(b.kind.stroke), width: 1))
                }
                for b in s.residential.prefix(150) {
                    let c = ResidentialGeo.centroid(b.points)
                    annotations.append(GEAnnotation(id: "res-\(b.id)", coord: c, reuse: "res") {
                        Color.clear.frame(width: 18, height: 18)
                    } onSelect: {
                        s.select(Entity.place(
                            lat: c.latitude, lon: c.longitude, name: b.name,
                            detail: "Residential · \(b.kind.rawValue)" + (b.levels.map { " · \($0) levels" } ?? ""),
                            distance: 1_500,
                            summary: "OSM building footprint · \(b.points.count) vertices",
                            extraMeta: [MetaRow("Building", b.kind.rawValue), MetaRow("Levels", b.levels ?? "—"), MetaRow("Source", "OpenStreetMap Overpass")]
                        ))
                    })
                }
            }

            if s.viewsheds, s.layers.contains(.cctv), s.distance < 6_000 {
                for cam in s.visibleCameras {
                    overlays.append(GEPolygon(
                        Geo.cone(at: cam.coord, heading: Geo.stableHeading(for: cam.id)),
                        fill: UIColor.purple.withAlphaComponent(0.18),
                        stroke: UIColor.purple.withAlphaComponent(0.6),
                        width: 1
                    ))
                }
            }

            for r in s.regions {
                for ring in r.rings {
                    overlays.append(GEPolygon(ring, fill: accent.withAlphaComponent(0.10), stroke: accent, width: 2))
                }
            }

            for q in s.visibleQuakes {
                let show = q.mag >= 5 && s.showLabels
                let qs = CGFloat(6 + max(0, q.mag - 1) * 3.2)
                annotations.append(GEAnnotation(id: "eq-\(q.id)", coord: q.coord, title: show ? String(format: "M%.1f", q.mag) : nil, reuse: "eq") {
                    ZStack {
                        Circle().fill(q.color.opacity(0.22)).frame(width: qs * 2, height: qs * 2)
                        Circle().stroke(q.color, lineWidth: 1.5).frame(width: qs, height: qs)
                    }
                    .frame(width: 28, height: 28)
                } onSelect: { s.select(Entity.from(q)) })
            }

            for l in s.visibleLaunches {
                annotations.append(GEAnnotation(id: "launch-\(l.id)", coord: l.coord, reuse: "launch") {
                    Image(systemName: l.net > Date() ? "flame" : "flame.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.pink)
                        .frame(width: 28, height: 28)
                } onSelect: { s.select(Entity.from(l)) })
            }

            for h in s.visibleHazards {
                for ring in h.rings {
                    overlays.append(GEPolygon(ring, fill: geUIColor(h.color).withAlphaComponent(0.18), stroke: geUIColor(h.color).withAlphaComponent(0.8), width: 1.5))
                }
                let show = s.distance < 2_000_000 && s.showLabels
                annotations.append(GEAnnotation(id: "haz-\(h.id)", coord: h.coord, title: show ? h.event : nil, reuse: "haz") {
                    Image(systemName: h.source == "Cal Fire" ? "flame.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(h.color)
                        .frame(width: 24, height: 24)
                } onSelect: { s.select(Entity.from(h)) })
            }

            for w in s.visibleStations {
                let show = s.showLabels && s.distance < 1_500_000
                let title = w.tempC.map { "\(Int($0))°" } ?? w.id
                annotations.append(GEAnnotation(id: "wx-\(w.id)", coord: w.coord, title: show ? title : nil, reuse: "wx") {
                    ZStack {
                        Circle().fill(Entity.Kind.station.color.opacity(0.2)).frame(width: 18, height: 18)
                        if let d = w.windDir, let k = w.windKt, k > 0 {
                            Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(d + 180)).foregroundStyle(Entity.Kind.station.color)
                        } else {
                            Image(systemName: w.kind == "BUOY" ? "water.waves" : "thermometer.medium").font(.system(size: 8)).foregroundStyle(Entity.Kind.station.color)
                        }
                    }
                    .frame(width: 24, height: 24)
                } onSelect: { s.select(Entity.from(w)) })
            }

            for st in s.storms {
                if st.history.count > 1 {
                    overlays.append(GEPolyline(st.history, stroke: geUIColor(Entity.Kind.storm.color), width: 2))
                }
                let proj = st.coord.moved(meters: st.speedKmh / 3.6 * 3600, bearing: st.headingDeg)
                overlays.append(GEPolyline([st.coord, proj], stroke: geUIColor(Entity.Kind.storm.color).withAlphaComponent(0.6), width: 2, dash: [6, 6]))
                annotations.append(GEAnnotation(id: "storm-p-\(st.id)", coord: proj, title: "+60 min", reuse: "stormp") {
                    Circle().stroke(Entity.Kind.storm.color, lineWidth: 1.5).frame(width: 14, height: 14)
                } onSelect: {})
                annotations.append(GEAnnotation(id: "storm-\(st.id)", coord: st.coord, reuse: "storm") {
                    Image(systemName: "cloud.bolt.rain.fill").foregroundStyle(Entity.Kind.storm.color).font(.title3)
                        .frame(width: 30, height: 30)
                } onSelect: { s.select(Entity.from(st)) })
            }

            if s.layers.contains(.space) {
                if s.night.count > 3 {
                    overlays.append(GEPolygon(s.night, fill: UIColor.black.withAlphaComponent(0.35), stroke: UIColor.yellow.withAlphaComponent(0.5), width: 1))
                }
                for a in s.auroraPoints {
                    annotations.append(GEAnnotation(id: "aur-\(a.id)", coord: a.coord, reuse: "aur") {
                        Circle().fill(Color.green.opacity(min(0.85, a.prob / 100 + 0.15))).frame(width: 6, height: 6)
                    } onSelect: {})
                }
                annotations.append(GEAnnotation(id: "sun", coord: Solar.subsolar(Date()), title: "SUN", reuse: "sun") {
                    Image(systemName: "sun.max.fill").foregroundStyle(.yellow).font(.title2)
                } onSelect: {})
            }

            if s.layers.contains(.wind) {
                for w in s.winds {
                    annotations.append(GEAnnotation(id: "wind-\(w.id)", coord: w.coord, reuse: "wind") {
                        VStack(spacing: 0) {
                            Image(systemName: "arrow.up").font(.system(size: 12 + min(w.speedKt, 40) / 4, weight: .bold))
                                .rotationEffect(.degrees(w.dirDeg + 180))
                                .foregroundStyle(w.speedKt > 25 ? .orange : .cyan)
                            Text("\(Int(w.speedKt))").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.cyan)
                        }
                    } onSelect: {})
                }
            }

            if s.layers.contains(.quakes), s.distance < 3_000_000 {
                for q in s.visibleQuakes.filter({ $0.mag >= 4 }) {
                    let col = q.depthKm < 70 ? UIColor.red : q.depthKm < 300 ? UIColor.orange : UIColor.blue
                    overlays.append(GECircle(center: q.coord, radius: pow(10, 0.5 * q.mag) * 120,
                                             fill: col.withAlphaComponent(0.12), stroke: col.withAlphaComponent(0.6), width: 1))
                }
            }

            for b in s.visibleBikes {
                annotations.append(GEAnnotation(id: "bike-\(b.id)", coord: b.coord, reuse: "bike") {
                    ZStack {
                        Circle().fill(Color.mint.opacity(0.25)).frame(width: 20, height: 20)
                        Text(b.bikes >= 0 ? "\(b.bikes)" : "?").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.mint)
                    }
                    .frame(width: 24, height: 24)
                } onSelect: { s.select(Entity.from(b)) })
            }

            for r in s.visibleRadio {
                annotations.append(GEAnnotation(id: "radio-\(r.id)", coord: r.coord, reuse: "radio") {
                    Image(systemName: s.radio.current?.id == r.id ? "dot.radiowaves.left.and.right" : "radio")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow)
                        .frame(width: 22, height: 22)
                } onSelect: { s.select(Entity.from(r)) })
            }

            if s.layers.contains(.infra), s.distance < 400_000 {
                for n in s.infra {
                    let show = s.distance < 30_000 && s.showLabels
                    annotations.append(GEAnnotation(id: "infra-\(n.id)", coord: n.coord, title: show ? n.name : nil, reuse: "infra") {
                        Image(systemName: n.kind.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.teal)
                            .frame(width: 22, height: 22)
                    } onSelect: { s.select(Entity.from(n)) })
                }
            }

            if s.layers.contains(.power), s.distance < 250_000 {
                for l in s.powerLines {
                    overlays.append(GEPolyline(l.points, stroke: geUIColor(l.color).withAlphaComponent(0.8), width: l.voltage >= 230_000 ? 2.5 : 1.5))
                }
                for n in s.powerNodes {
                    let show = s.distance < 40_000 && s.showLabels
                    annotations.append(GEAnnotation(id: "pwr-\(n.id)", coord: n.coord, title: show ? n.name : nil, reuse: "pwr") {
                        Image(systemName: n.kind.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow)
                            .frame(width: 22, height: 22)
                    } onSelect: { s.select(Entity.from(n)) })
                }
            }

            if s.layers.contains(.rail), s.distance < 150_000 {
                for l in s.railLines {
                    let col: UIColor = {
                        switch l.kind {
                        case "yard": return .gray
                        case "subway": return .orange
                        case "tram", "light_rail": return .systemMint
                        default: return geUIColor(Entity.Kind.train.color)
                        }
                    }()
                    let dash: [CGFloat] = l.kind == "rail" ? [] : [4, 3]
                    overlays.append(GEPolyline(l.points, stroke: col, width: l.kind == "yard" ? 1 : 2, dash: dash))
                }
                for st in s.railStations {
                    let show = s.distance < 25_000 && s.showLabels
                    annotations.append(GEAnnotation(id: "rst-\(st.id)", coord: st.coord, title: show ? st.name : nil, reuse: "rst") {
                        Circle().fill(.white).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Entity.Kind.train.color, lineWidth: 1.5))
                            .frame(width: 18, height: 18)
                    } onSelect: {
                        s.select(Entity.place(lat: st.lat, lon: st.lon, name: st.name, detail: "Rail \(st.kind)", distance: 3_000))
                    })
                }
            }

            for t in s.visibleTrains {
                let show = s.distance < 600_000 && s.showLabels
                annotations.append(GEAnnotation(id: "train-\(t.id)", coord: t.coord, title: show ? t.name : nil, reuse: "train") {
                    MarkerGlyph(system: "train.side.front.car", color: Entity.Kind.train.color, size: 12, rotation: 0, id: t.id, tracked: s.trackedID == "train-\(t.id)", detection: s.detection)
                } onSelect: { s.select(Entity.from(t)) })
            }

            if s.layers.contains(.scanner) {
                for f in s.scanners {
                    annotations.append(GEAnnotation(id: "scan-\(f.id)", coord: f.coord, reuse: "scan") {
                        Image(systemName: s.scannerNow?.id == f.id ? "speaker.wave.2.fill" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(Entity.Kind.scanner.color)
                            .frame(width: 24, height: 24)
                    } onSelect: { s.select(Entity.from(f)) })
                }
            }

            if s.layers.contains(.peaks), s.distance < 300_000 {
                for p in s.peaks.prefix(120) {
                    let show = s.distance < 80_000 && s.showLabels
                    annotations.append(GEAnnotation(id: "peak-\(p.id)", coord: p.coord, title: show ? "\(p.name) \(Int(p.elevationM))m" : nil, reuse: "peak") {
                        Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(Entity.Kind.peak.color)
                            .frame(width: 20, height: 20)
                    } onSelect: { s.select(Entity.from(p)) })
                }
            }

            // Radar ground overlays
            if let c = s.radar.satComposite, s.layers.contains(.satir) {
                if let o = RadarMapOverlay.groundOverlay(for: c, opacity: s.radarOpacity * 0.6) { overlays.append(o) }
            }
            if let c = s.radar.composite, s.layers.contains(.radar) {
                if let o = RadarMapOverlay.groundOverlay(for: c, opacity: s.radarOpacity) { overlays.append(o) }
            }
        }
    }
}

// MARK: - Radar ground overlay helper

enum RadarMapOverlay {
    static func groundOverlay(for composite: RadarComposite, opacity: Double) -> MKGroundOverlay? {
        let nw = composite.nw
        let se = composite.se
        let sw = CLLocationCoordinate2D(
            latitude: min(nw.latitude, se.latitude),
            longitude: min(nw.longitude, se.longitude)
        )
        let ne = CLLocationCoordinate2D(
            latitude: max(nw.latitude, se.latitude),
            longitude: max(nw.longitude, se.longitude)
        )
        let swP = MKMapPoint(sw)
        let neP = MKMapPoint(ne)
        // MapKit y increases southward.
        let rect = MKMapRect(
            x: min(swP.x, neP.x),
            y: min(swP.y, neP.y),
            width: abs(neP.x - swP.x),
            height: abs(neP.y - swP.y)
        )
        guard rect.width > 0, rect.height > 0 else { return nil }
        let overlay = MKGroundOverlay(bounds: rect, icon: composite.image)
        overlay.alpha = CGFloat(opacity)
        return overlay
    }
}

// MARK: - Overlay / annotation types

final class GEPolyline: MKPolyline {
    var strokeColor: UIColor = .white
    var lineWidth: CGFloat = 2
    var dash: [NSNumber]?

    convenience init(_ coords: [CLLocationCoordinate2D], stroke: UIColor, width: CGFloat, dash: [CGFloat] = []) {
        var copy = coords
        self.init(coordinates: &copy, count: copy.count)
        self.strokeColor = stroke
        self.lineWidth = width
        self.dash = dash.isEmpty ? nil : dash.map { NSNumber(value: Double($0)) }
    }
}

final class GEPolygon: MKPolygon {
    var fillColor: UIColor = .clear
    var strokeColor: UIColor = .white
    var lineWidth: CGFloat = 1
    var dash: [NSNumber]?

    convenience init(_ coords: [CLLocationCoordinate2D], fill: UIColor, stroke: UIColor, width: CGFloat, dash: [CGFloat] = []) {
        var copy = coords
        self.init(coordinates: &copy, count: copy.count)
        self.fillColor = fill
        self.strokeColor = stroke
        self.lineWidth = width
        self.dash = dash.isEmpty ? nil : dash.map { NSNumber(value: Double($0)) }
    }
}

final class GECircle: MKCircle {
    var fillColor: UIColor = .clear
    var strokeColor: UIColor = .white
    var lineWidth: CGFloat = 1

    convenience init(center: CLLocationCoordinate2D, radius: CLLocationDistance, fill: UIColor, stroke: UIColor, width: CGFloat) {
        self.init(center: center, radius: radius)
        self.fillColor = fill
        self.strokeColor = stroke
        self.lineWidth = width
    }
}

final class GEAnnotation: NSObject, MKAnnotation {
    let id: String
    let reuseId: String
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    let makeContent: () -> AnyView
    let onSelect: () -> Void

    init<V: View>(
        id: String,
        coord: CLLocationCoordinate2D,
        title: String? = nil,
        reuse: String,
        @ViewBuilder content: @escaping () -> V,
        onSelect: @escaping () -> Void
    ) {
        self.id = id
        self.reuseId = reuse
        self.coordinate = coord
        self.title = title
        self.makeContent = { AnyView(content()) }
        self.onSelect = onSelect
        super.init()
    }
}

final class GEHostingAnnotationView: MKAnnotationView {
    private var host: UIHostingController<AnyView>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        canShowCallout = false
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ ge: GEAnnotation) {
        annotation = ge
        let root = ge.makeContent()
        if let host {
            host.rootView = root
        } else {
            let hc = UIHostingController(rootView: root)
            hc.view.backgroundColor = .clear
            hc.view.isUserInteractionEnabled = false
            hc.view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hc.view)
            NSLayoutConstraint.activate([
                hc.view.centerXAnchor.constraint(equalTo: centerXAnchor),
                hc.view.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            host = hc
        }
        host?.view.invalidateIntrinsicContentSize()
        host?.view.sizeToFit()
        let size = host?.view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) ?? CGSize(width: 28, height: 28)
        let side = max(max(size.width, size.height), 24)
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        centerOffset = .zero
        canShowCallout = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        host?.rootView = AnyView(EmptyView())
    }
}

// MARK: - Color → UIColor (iOS 16)

private var geColorCache: [String: UIColor] = [:]

/// Samples a SwiftUI `Color` into `UIColor` without iOS 17 `UIColor(Color)`.
private func geUIColor(_ color: Color) -> UIColor {
    let key = String(describing: color)
    if let cached = geColorCache[key] { return cached }
    let renderer = ImageRenderer(content: Rectangle().fill(color).frame(width: 2, height: 2))
    renderer.scale = 1
    var result = UIColor.white
    if let img = renderer.uiImage, let cg = img.cgImage {
        var pixel = [UInt8](repeating: 0, count: 4)
        if let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let a = max(CGFloat(pixel[3]) / 255, 0.001)
            result = UIColor(
                red: min(1, CGFloat(pixel[0]) / 255 / a),
                green: min(1, CGFloat(pixel[1]) / 255 / a),
                blue: min(1, CGFloat(pixel[2]) / 255 / a),
                alpha: CGFloat(pixel[3]) / 255
            )
        }
    }
    geColorCache[key] = result
    return result
}
