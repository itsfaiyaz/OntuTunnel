import AppKit
import Foundation

/// Sample data for screenshots: start with ONTUTUNNEL_DEMO=1. Nothing is
/// saved, nothing is checked or connected, the real config is untouched.
/// Addresses are from the documentation ranges (RFC 5737), domains are example.com.
enum Demo {
    static let on = ProcessInfo.processInfo.environment["ONTUTUNNEL_DEMO"] == "1"
    static let serverIP = "203.0.113.10"

    /// ONTUTUNNEL_DEMO_SELECT=Shop opens that site's details panel.
    static var preselect: UUID? {
        guard on, let name = ProcessInfo.processInfo.environment["ONTUTUNNEL_DEMO_SELECT"] else { return nil }
        return shared.services.first { $0.name == name }?.id
    }
    /// Same service ids for the whole run.
    static let shared = config

    static var config: AppConfig {
        var c = AppConfig()
        c.mode = .relay
        c.server = ServerConfig()
        c.server.host = "vps.example.com"
        c.server.user = "ubuntu"
        c.server.email = "admin@example.com"
        c.serverMode = .nginx
        c.wildcardBases = ["dev.example.com"]
        c.web.enabled = false
        c.hiddenPorts = [5432, 6379]
        func svc(_ name: String, _ domain: String, _ port: Int, _ remote: Int, cmd: String = "") -> Service {
            var s = Service(name: name, domain: domain, localPort: port)
            s.remotePort = remote
            s.startCommand = cmd
            s.keepAlive = !cmd.isEmpty
            return s
        }
        var erp = svc("ERPNext", "erp.example.com", 8000, 31842, cmd: "bench start")
        erp.frappeSite = "erp.localhost"
        erp.socketPort = 9000
        erp.remoteSocketPort = 31843
        c.services = [
            svc("Shop", "shop.dev.example.com", 3000, 27411, cmd: "npm run dev"),
            erp,
            svc("Blog", "blog.dev.example.com", 5173, 29904, cmd: "npm run dev"),
            svc("API", "api.dev.example.com", 4000, 35127),
            svc("Docs", "docs.dev.example.com", 8080, 24418),
        ]
        return c
    }

    @MainActor static func fill(_ m: AppModel) {
        if let look = ProcessInfo.processInfo.environment["ONTUTUNNEL_DEMO_LOOK"] {
            NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
        }
        NSApp.activate(ignoringOtherApps: true)
        m.serverIP = serverIP
        m.connection = .ok
        m.tunnelState = .connected(Date().addingTimeInterval(-3 * 3600 - 1260))
        m.network = NetworkSnapshot(interface: "en0", localIPv4: "192.168.1.24", router: "192.168.1.1",
                                    ipv6: "", publicIPv4: "198.51.100.7", checkedAt: Date())
        m.localPorts = [
            ListeningPort(port: 3000, process: "node", address: "127.0.0.1"),
            ListeningPort(port: 4000, process: "node", address: "127.0.0.1"),
            ListeningPort(port: 5173, process: "node", address: "127.0.0.1"),
            ListeningPort(port: 8000, process: "python3", address: "127.0.0.1"),
            ListeningPort(port: 8080, process: "python3", address: "127.0.0.1"),
            ListeningPort(port: 8888, process: "jupyter", address: "127.0.0.1"),
            ListeningPort(port: 9000, process: "node", address: "127.0.0.1"),
            ListeningPort(port: 5432, process: "postgres", address: "127.0.0.1"),
            ListeningPort(port: 6379, process: "redis-server", address: "127.0.0.1"),
        ]
        m.wildcardStatus = ["dev.example.com": .ok]
        for s in m.config.services {
            var st = ServiceStatus()
            st.port = .open
            st.process = s.hasCommand ? .running : .none
            st.dnsA = [serverIP]
            st.dns = .ok
            st.live = .ok
            st.liveCheckedAt = Date().addingTimeInterval(-40)
            if s.name == "Docs" { st.live = .warning("HTTPS certificate is being issued") }
            m.status[s.id] = st
        }
        m.log("Server", "Connected to \(serverIP) — nginx found, OntuTunnel adds only its own files")
        m.log("Server", "Published 5 site(s) (nginx)")
        m.log("Tunnel", "Tunnel up: 6 ports")
    }
}
