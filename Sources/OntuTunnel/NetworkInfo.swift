import Foundation
import Network

/// Addresses of this Mac.
struct NetworkSnapshot: Equatable {
    var interface = ""
    var localIPv4 = ""
    var router = ""
    /// Stable global IPv6 of this Mac.
    var ipv6 = ""
    /// What the internet sees for IPv4 (often shared/CGNAT on home connections).
    var publicIPv4 = ""
    var checkedAt: Date?
}

enum NetworkInfo {
    static func snapshot() async -> NetworkSnapshot {
        var snap = await Task.detached { local() }.value
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 6
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            snap.publicIPv4 = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        snap.checkedAt = Date()
        return snap
    }

    static func local() -> NetworkSnapshot {
        var snap = NetworkSnapshot()
        for line in Shell.run("/sbin/route", ["-n", "get", "default"]).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "interface" { snap.interface = parts[1] }
            if parts[0] == "gateway" { snap.router = parts[1] }
        }
        guard !snap.interface.isEmpty else { return snap }
        for raw in Shell.run("/sbin/ifconfig", [snap.interface]).split(separator: "\n") {
            let words = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard words.count >= 2 else { continue }
            if words[0] == "inet", snap.localIPv4.isEmpty { snap.localIPv4 = words[1] }
            if words[0] == "inet6", snap.ipv6.isEmpty, let first = words[1].first, first == "2" || first == "3",
               !words.contains("temporary"), !words.contains("deprecated") {
                snap.ipv6 = words[1]
            }
        }
        return snap
    }
}

/// A TCP port something on this Mac is listening on.
struct ListeningPort: Identifiable, Hashable {
    var id: Int { port }
    let port: Int
    let process: String
    let address: String
}

enum LocalPorts {
    /// Programs that are part of macOS or common desktop apps — not dev servers.
    private static let ignored: Set<String> = [
        "ControlCe", "rapportd", "launchd", "mDNSRespo", "sharingd", "AirPlayXP", "identitys",
        "LogiPlugi", "logioptio", "LocalBrid", "OntuTunnel", "cloudflar", "Electron", "stable",
        "language_", "Antigravi", "Dropbox", "Spotify", "zoom.us", "AnyDesk", "TeamViewe",
    ]

    static func scan() -> [ListeningPort] {
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fcn"])
        var result: [Int: ListeningPort] = [:]
        var command = ""
        for line in out.split(separator: "\n") {
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            else if line.hasPrefix("n") {
                let addr = String(line.dropFirst())
                guard let port = Int(addr.split(separator: ":").last ?? ""), port < 49152 else { continue }
                if ignored.contains(where: { command.hasPrefix($0) }) { continue }
                if result[port] == nil { result[port] = ListeningPort(port: port, process: command, address: addr) }
            }
        }
        return result.values.sorted { $0.port < $1.port }
    }
}

enum DNSLookup {
    /// Public DNS answer (via 1.1.1.1, so local caches don't hide changes).
    /// Asks Google and Cloudflare; the first one that knows the record wins
    /// (one of them may still cache an old "no record" answer for a while).
    static func a(_ domain: String) -> [String] {
        guard !domain.isEmpty else { return [] }
        for resolver in ["8.8.8.8", "1.1.1.1"] {
            let out = Shell.run("/usr/bin/dig", ["+short", "+time=3", "+tries=1", "A", domain, "@\(resolver)"])
            let ips = out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.split(separator: ".").count == 4 && $0.first?.isNumber == true }
            if !ips.isEmpty { return ips }
        }
        return []
    }

    /// The server's IP: `host` itself if it is an IP, the HostName of an
    /// ~/.ssh/config alias (e.g. "my-vm"), else its DNS A record.
    static func resolveHost(_ host: String) -> String {
        func isIP(_ h: String) -> Bool { h.split(separator: ".").count == 4 && h.allSatisfy { $0.isNumber || $0 == "." } }
        if isIP(host) { return host }
        let real = Shell.run("/usr/bin/ssh", ["-G", host]).split(separator: "\n")
            .first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst(9)) } ?? host
        if isIP(real) { return real }
        return a(real).first ?? real
    }
}

enum PortProbe {
    /// Is something accepting connections on localhost:port (IPv4 or IPv6)?
    static func isOpen(_ port: Int, timeout: TimeInterval = 1.5) async -> Bool {
        if await isOpen(host: "127.0.0.1", port: port, timeout: timeout) { return true }
        return await isOpen(host: "::1", port: port, timeout: timeout)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    private static func isOpen(host: NWEndpoint.Host, port: Int, timeout: TimeInterval) async -> Bool {
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: host, port: nwPort, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { value in
                once.run {
                    conn.cancel()
                    cont.resume(returning: value)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

enum LiveCheck {
    /// HTTPS request from this Mac to the domain, using the public DNS answer
    /// (Google/Cloudflare) instead of the Mac's own cache, so a stale record
    /// in the home router doesn't give a wrong result. Goes out to the server
    /// and back through the tunnel, so success means the whole chain works.
    static func check(_ domain: String) async -> Check {
        await Task.detached {
            let ips = DNSLookup.a(domain)
            guard let ip = ips.first else { return Check.failed("Domain has no A record in public DNS") }
            let out = Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "12",
                                                  "--resolve", "\(domain):443:\(ip)",
                                                  "-w", "%{http_code} %{ssl_verify_result}",
                                                  "https://\(domain)/"])
            let parts = out.split(separator: " ")
            let code = Int(parts.first ?? "") ?? 0
            let verify = Int(parts.dropFirst().first ?? "") ?? -1
            if code == 0 {
                return verify > 0 ? Check.warning("HTTPS certificate not ready yet")
                                  : Check.failed("Server \(ip) not reachable on port 443 (firewall?)")
            }
            if verify > 0 { return Check.warning("HTTPS certificate not valid yet") }
            if code == 502 || code == 503 || code == 504 { return Check.failed("Server can't reach this Mac (HTTP \(code)) — tunnel or local app down") }
            if code >= 500 { return Check.warning("Your app answered HTTP \(code)") }
            return Check.ok
        }.value
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
