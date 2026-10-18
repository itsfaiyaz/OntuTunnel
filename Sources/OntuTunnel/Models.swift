import Foundation

/// The relay server: a machine with a static public IP that visitors reach.
/// OntuTunnel connects to it over SSH and tunnels traffic back to this Mac.
struct ServerConfig: Codable, Equatable {
    var host: String = ""
    var user: String = ""
    var port: Int = 22
    var keyPath: String = "~/.ssh/id_ed25519"
    /// Optional — Let's Encrypt sends certificate expiry notices here.
    var email: String = ""

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var expandedKeyPath: String { (keyPath as NSString).expandingTildeInPath }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? "~/.ssh/id_ed25519"
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
    }
}

/// How visitors reach this Mac.
enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    /// A server with a static IP; this Mac keeps an SSH tunnel to it.
    case relay
    /// This internet connection has its own static public IPv4 (e.g. bought
    /// from Jio): the router forwards 80/443 to this Mac, which serves the
    /// sites itself with its own HTTPS. No server needed.
    case staticIP
    /// Cloudflare Tunnel: no server, no static IP — the domain is on
    /// Cloudflare and cloudflared on this Mac connects out to Cloudflare.
    case cloudflare

    var id: String { rawValue }
    var title: String {
        switch self {
        case .relay: return "My server (SSH)"
        case .staticIP: return "My static IP"
        case .cloudflare: return "Cloudflare Tunnel"
        }
    }
    var subtitle: String {
        switch self {
        case .relay: return "A VPS / Google Cloud VM with a static IP"
        case .staticIP: return "Static public IP from your ISP, no server"
        case .cloudflare: return "Free, no server and no static IP"
        }
    }
    var icon: String {
        switch self {
        case .relay: return "server.rack"
        case .staticIP: return "wifi.router"
        case .cloudflare: return "cloud"
        }
    }
}

struct StaticIPConfig: Codable, Equatable {
    /// Leave empty to use the public IPv4 detected right now.
    var ip: String = ""
    var httpsEnabled: Bool = true
    var redirectToHTTPS: Bool = true
    var email: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        httpsEnabled = try c.decodeIfPresent(Bool.self, forKey: .httpsEnabled) ?? true
        redirectToHTTPS = try c.decodeIfPresent(Bool.self, forKey: .redirectToHTTPS) ?? true
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
    }
}

struct WebConfig: Codable, Equatable {
    var enabled: Bool = true
    var port: Int = 7777
    /// Also reachable from other devices on this network (needs the key).
    var allowLAN: Bool = false
    var key: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7777
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
    }
}

struct CloudflareConfig: Codable, Equatable {
    var tunnelName: String = ""
    var tunnelID: String = ""
    /// Local port the proxy listens on for cloudflared (127.0.0.1 only).
    var proxyPort: Int = 0
    /// Domains already routed to the tunnel in Cloudflare DNS.
    var routed: [String] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tunnelName = try c.decodeIfPresent(String.self, forKey: .tunnelName) ?? ""
        tunnelID = try c.decodeIfPresent(String.self, forKey: .tunnelID) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 0
        routed = try c.decodeIfPresent([String].self, forKey: .routed) ?? []
    }
}

/// How the server publishes sites, decided when it is set up.
enum ServerMode: String, Codable {
    /// Ports 80/443 were free: OntuTunnel runs its own Caddy
    /// (service "ontutunnel-caddy"), which also does HTTPS by itself.
    case caddy
    /// nginx already owns 80/443: OntuTunnel only adds its own files
    /// (/etc/nginx/conf.d/ontutunnel-*.conf) and uses certbot for HTTPS.
    case nginx
}

/// One local app published on a domain, e.g.
/// shop.example.com → this Mac's localhost:8001.
struct Service: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var domain: String = ""
    var localPort: Int = 8001
    /// Frappe/bench: site to serve (sent as X-Frappe-Site-Name).
    var frappeSite: String = ""
    /// Optional Socket.IO / realtime port (bench: 9001).
    var socketPort: Int = 0
    var enabled: Bool = true

    var startCommand: String = ""
    var workingDirectory: String = ""
    var autoStart: Bool = false
    var keepAlive: Bool = false

    /// Ports on the server's 127.0.0.1 the tunnel uses for this service —
    /// picked at random among ports nothing else on the server uses.
    var remotePort: Int = 0
    var remoteSocketPort: Int = 0

    var normalizedDomain: String { domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var hasCommand: Bool { !startCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(name: String = "", domain: String = "", localPort: Int = 8001) {
        self.name = name
        self.domain = domain
        self.localPort = localPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 8001
        frappeSite = try c.decodeIfPresent(String.self, forKey: .frappeSite) ?? ""
        socketPort = try c.decodeIfPresent(Int.self, forKey: .socketPort) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        startCommand = try c.decodeIfPresent(String.self, forKey: .startCommand) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? false
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? 0
        remoteSocketPort = try c.decodeIfPresent(Int.self, forKey: .remoteSocketPort) ?? 0
    }
}

struct AppConfig: Codable {
    var mode: ConnectionMode = .relay
    var staticIP = StaticIPConfig()
    var cloudflare = CloudflareConfig()
    var server = ServerConfig()
    var serverMode: ServerMode?
    var services: [Service] = []
    /// Start the tunnel when OntuTunnel opens.
    var autoConnect: Bool = true
    /// Stop the Mac from going to sleep on its own while OntuTunnel runs.
    var keepAwake: Bool = false
    /// "system", "light" or "dark".
    var appearance: String = "system"
    /// "My static IP" adds the sites to /etc/hosts (127.0.0.1) unless off.
    var localHostsOff: Bool = false
    /// Ports hidden from "Running on this Mac" (databases, caches, …).
    var hiddenPorts: [Int] = []
    /// Wildcard bases, e.g. "dev.example.com": DNS has *.dev.example.com → this
    /// connection's IP, so any name under it works without a DNS step.
    var wildcardBases: [String] = []
    /// Domains this Mac has published on the server. Cleanup only removes
    /// these, never files another computer wrote. nil = config from before
    /// this was tracked (then every ontutunnel-* file is ours).
    var published: [String]?
    var web = WebConfig()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ConnectionMode.self, forKey: .mode) ?? .relay
        staticIP = try c.decodeIfPresent(StaticIPConfig.self, forKey: .staticIP) ?? StaticIPConfig()
        cloudflare = try c.decodeIfPresent(CloudflareConfig.self, forKey: .cloudflare) ?? CloudflareConfig()
        server = try c.decodeIfPresent(ServerConfig.self, forKey: .server) ?? ServerConfig()
        serverMode = try c.decodeIfPresent(ServerMode.self, forKey: .serverMode)
        services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        localHostsOff = try c.decodeIfPresent(Bool.self, forKey: .localHostsOff) ?? false
        hiddenPorts = try c.decodeIfPresent([Int].self, forKey: .hiddenPorts) ?? []
        wildcardBases = try c.decodeIfPresent([String].self, forKey: .wildcardBases) ?? []
        published = try c.decodeIfPresent([String].self, forKey: .published)
        web = try c.decodeIfPresent(WebConfig.self, forKey: .web) ?? WebConfig()
    }
}

enum ConfigFile {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OntuTunnel", isDirectory: true)
        // one-time move from the app's old name (LocalBridge)
        let old = support.appendingPathComponent("LocalBridge", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        if Demo.on { return Demo.shared }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    static func save(_ config: AppConfig) {
        if Demo.on { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Runtime status (not saved)

enum Check: Equatable {
    case unknown, checking, ok, warning(String), failed(String)

    var isOK: Bool { self == .ok }
}

enum PortState: Equatable { case unknown, open, closed }

enum ProcessState: Equatable {
    case none, running, stopped, crashed(Int32)

    var label: String {
        switch self {
        case .none: return "No command"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .crashed(let code): return "Exited (\(code))"
        }
    }
}

struct ServiceStatus {
    var port: PortState = .unknown
    var process: ProcessState = .none
    /// A records of the domain.
    var dnsA: [String] = []
    var dns: Check = .unknown
    /// End-to-end: https://domain answered through the server and tunnel.
    var live: Check = .unknown
    var liveCheckedAt: Date?
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let source: String
    let text: String
    let isError: Bool
}

/// One visible step of "Set up server".
struct SetupStep: Identifiable {
    let id = UUID()
    let title: String
    var state: Check = .unknown
    var detail: String = ""
}

/// One SSH key pair in ~/.ssh.
struct SSHKeyInfo: Identifiable, Hashable {
    let path: String        // "~/.ssh/id_ed25519" (private key)
    let publicKey: String   // "ssh-ed25519 AAAA… comment"
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var type: String {
        let t = publicKey.split(separator: " ").first.map(String.init) ?? ""
        return t.replacingOccurrences(of: "ssh-", with: "").uppercased()
    }
    var comment: String {
        let parts = publicKey.split(separator: " ", maxSplits: 2)
        return parts.count == 3 ? String(parts[2]) : ""
    }
    /// The user Google Cloud creates for this key (the comment before "@").
    var cloudUser: String {
        let u = comment.split(separator: "@").first.map(String.init) ?? ""
        return AppModel.validUserName(u.lowercased()) ? u.lowercased() : ""
    }
}
