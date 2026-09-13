import Foundation
import CoreLocation
import Darwin

// MARK: - Saved traces (bookmark a trace, replay it instantly without re-running it)

struct SavedTrace: Identifiable, Codable {
    let id: UUID
    let target: String
    let hops: [NetHop]
    let date: Date
    init(target: String, hops: [NetHop]) { self.id = UUID(); self.target = target; self.hops = hops; self.date = Date() }
}

// MARK: - Hop model

struct NetHop: Identifiable, Equatable, Codable {
    let id = UUID()
    let ttl: Int
    var ip: String?
    var rttMs: Double?
    var city: String?
    var country: String?
    var countryCode: String?
    var lat: Double?
    var lon: Double?
    var asn: String?
    var isp: String?

    var coord: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    var responded: Bool { ip != nil }
    var label: String { city.map { c in country.map { "\(c), \($0)" } ?? c } ?? (ip ?? "no response") }

    static func == (a: NetHop, b: NetHop) -> Bool { a.id == b.id }
}

// MARK: - Geolocation enrichment (keyless, https, no API key required)

enum GeoIP {
    struct Info { let city: String?; let country: String?; let countryCode: String?; let lat: Double?; let lon: Double?; let asn: String?; let isp: String? }

    static func lookup(ip: String) async -> Info? {
        guard let url = URL(string: "https://ipwho.is/\(ip)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ok = json["success"] as? Bool, ok == false { return nil }
        let connection = json["connection"] as? [String: Any]
        let asnRaw = connection?["asn"]
        let asn = (asnRaw as? Int).map { "AS\($0)" } ?? (asnRaw as? String).map { $0.hasPrefix("AS") ? $0 : "AS\($0)" }
        return Info(city: json["city"] as? String,
                    country: json["country"] as? String,
                    countryCode: json["country_code"] as? String,
                    lat: json["latitude"] as? Double,
                    lon: json["longitude"] as? Double,
                    asn: asn,
                    isp: (connection?["isp"] as? String) ?? (connection?["org"] as? String))
    }
}

// MARK: - RDAP (WHOIS) — IETF standard JSON, resolved via the rdap.org bootstrap redirector (keyless, real registry data)

struct RDAPEntity: Identifiable { let id = UUID(); let role: String; let name: String; let address: String? }

struct RDAPRecord {
    var name: String?
    var handle: String?
    var startAddress: String?
    var endAddress: String?
    var cidr: String?
    var country: String?
    var type: String?
    var registered: String?
    var lastChanged: String?
    var entities: [RDAPEntity] = []

    var ipRange: String? {
        guard let s = startAddress, let e = endAddress else { return nil }
        return "\(s) - \(e)"
    }

    static func parse(_ json: [String: Any]) -> RDAPRecord {
        var r = RDAPRecord()
        r.name = json["name"] as? String
        r.handle = json["handle"] as? String
        r.startAddress = json["startAddress"] as? String
        r.endAddress = json["endAddress"] as? String
        r.country = json["country"] as? String
        r.type = json["type"] as? String
        if let cidrs = json["cidr0_cidrs"] as? [[String: Any]], let first = cidrs.first {
            let prefix = (first["v4prefix"] as? String) ?? (first["v6prefix"] as? String)
            if let prefix, let length = first["length"] as? Int { r.cidr = "\(prefix)/\(length)" }
        }
        if let events = json["events"] as? [[String: Any]] {
            for e in events {
                guard let action = e["eventAction"] as? String, let date = e["eventDate"] as? String else { continue }
                if action == "registration" { r.registered = String(date.prefix(10)) }
                if action == "last changed" { r.lastChanged = String(date.prefix(10)) }
            }
        }
        if let entities = json["entities"] as? [[String: Any]] {
            for ent in entities {
                let roles = (ent["roles"] as? [String]) ?? ["entity"]
                var name = (ent["handle"] as? String) ?? "—"
                var address: String? = nil
                if let vcard = ent["vcardArray"] as? [Any], vcard.count > 1, let fields = vcard[1] as? [[Any]] {
                    for f in fields {
                        guard f.count >= 4, let key = f[0] as? String else { continue }
                        if key == "fn", let v = f[3] as? String { name = v }
                        if key == "adr", let v = f[3] as? [String] { address = v.filter { !$0.isEmpty }.joined(separator: ", ") }
                    }
                }
                for role in roles { r.entities.append(RDAPEntity(role: role, name: name, address: address)) }
            }
        }
        return r
    }
}

enum RDAPClient {
    static func lookup(ip: String) async -> RDAPRecord? {
        guard let url = URL(string: "https://rdap.org/ip/\(ip)") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return RDAPRecord.parse(json)
    }
}

// MARK: - ICMP traceroute (SOCK_DGRAM ICMP — works on iOS/macOS without root, same mechanism as Apple's SimplePing)

final class Traceroute {

    /// Runs a real hop-by-hop ICMP traceroute against `host` (hostname or IPv4 literal).
    /// Reports each hop as soon as it resolves via `onHop`, then geo/RDAP-enriches afterward.
    static func run(host: String, maxHops: Int = 30, timeoutSeconds: Double = 1.2, onHop: @escaping (NetHop) -> Void) async {
        guard let destAddr = resolve(host: host) else {
            onHop(NetHop(ttl: 0, ip: nil, rttMs: nil))
            return
        }
        await Task.detached(priority: .userInitiated) {
            probe(destAddr: destAddr, maxHops: maxHops, timeoutSeconds: timeoutSeconds, onHop: onHop)
        }.value
    }

    private static func resolve(host: String) -> sockaddr_in? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_ICMP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let res = result else { return nil }
        defer { freeaddrinfo(result) }
        var addr = sockaddr_in()
        withUnsafeMutableBytes(of: &addr) { dst in
            _ = memcpy(dst.baseAddress, res.pointee.ai_addr, MemoryLayout<sockaddr_in>.size)
        }
        return addr
    }

    private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    private static func echoPacket(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 16)
        pkt[0] = 8   // ICMP Echo Request
        pkt[1] = 0
        pkt[4] = UInt8(identifier >> 8); pkt[5] = UInt8(identifier & 0xFF)
        pkt[6] = UInt8(sequence >> 8); pkt[7] = UInt8(sequence & 0xFF)
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        for k in 0..<8 { pkt[8 + k] = UInt8((ts >> (8 * (7 - k))) & 0xFF) }
        let sum = checksum(pkt)
        pkt[2] = UInt8(sum >> 8); pkt[3] = UInt8(sum & 0xFF)
        return pkt
    }

    /// Skips a leading IPv4 header if present (DGRAM ICMP sockets sometimes hand back the IP header too) and returns the ICMP payload.
    private static func stripIPHeader(_ buf: [UInt8]) -> [UInt8] {
        guard buf.count > 20, (buf[0] >> 4) == 4 else { return buf }
        let ihl = Int(buf[0] & 0x0F) * 4
        guard buf.count > ihl else { return buf }
        return Array(buf[ihl...])
    }

    private static func probe(destAddr: sockaddr_in, maxHops: Int, timeoutSeconds: Double, onHop: @escaping (NetHop) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            onHop(NetHop(ttl: 0, ip: nil, rttMs: nil))
            return
        }
        defer { close(fd) }
        let identifier = UInt16(getpid() & 0xFFFF)
        var destReached = false

        for ttl in 1...maxHops {
            var ttlVal = Int32(ttl)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &ttlVal, socklen_t(MemoryLayout<Int32>.size))

            let packet = echoPacket(identifier: identifier, sequence: UInt16(ttl))
            var dest = destAddr
            let sent: Int = packet.withUnsafeBufferPointer { buf in
                withUnsafePointer(to: &dest) { dp -> Int in
                    dp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        sendto(fd, buf.baseAddress, buf.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent > 0 else {
                onHop(NetHop(ttl: ttl, ip: nil, rttMs: nil))
                continue
            }
            let sendTime = Date()

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeoutSeconds * 1000))

            if ready <= 0 {
                onHop(NetHop(ttl: ttl, ip: nil, rttMs: nil))
                continue
            }

            var buf = [UInt8](repeating: 0, count: 1024)
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = buf.withUnsafeMutableBufferPointer { bp in
                withUnsafeMutablePointer(to: &fromAddr) { fp -> Int in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(fd, bp.baseAddress, bp.count, 0, sp, &fromLen)
                    }
                }
            }
            guard n > 0 else {
                onHop(NetHop(ttl: ttl, ip: nil, rttMs: nil))
                continue
            }
            let rtt = Date().timeIntervalSince(sendTime) * 1000
            var ipBuf = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var srcAddr = fromAddr.sin_addr
            let ipStr = inet_ntop(AF_INET, &srcAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) }

            let icmp = stripIPHeader(Array(buf.prefix(n)))
            let type = icmp.first ?? 255
            onHop(NetHop(ttl: ttl, ip: ipStr, rttMs: rtt))

            if type == 0 { destReached = true; break }        // Echo Reply — reached destination
            // type 11 = Time Exceeded (intermediate hop) — keep going regardless of exact match
        }
        if !destReached {
            // implicit: caller's UI already shows every recorded ttl; no extra action needed
        }
    }
}
