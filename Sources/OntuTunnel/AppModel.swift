import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig { didSet { ConfigFile.save(config) } }
    @Published var status: [UUID: ServiceStatus] = [:]
    @Published var logs: [LogLine] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    // server
    @Published var connection: Check = .unknown          // SSH test
    @Published var facts: RemoteServer.Facts?
    @Published var steps: [SetupStep] = []
    @Published var busy = false
    @Published var serverIP = ""
    @Published var tunnelState: Tunnel.State = .stopped
    @Published var syncMessage = ""

    // this Mac
    @Published var network = NetworkSnapshot()
    @Published var localPorts: [ListeningPort] = []

    // static IP + Cloudflare modes: OntuTunnel's own proxy on this Mac
    let proxy = ProxyServer()
    @Published var proxyState: ProxyServer.State = .stopped
    @Published var httpsState: ProxyServer.State = .stopped
    @Published var certificate: StoredCertificate?
    @Published var certBusy = false
    @Published var certMessage = ""
    @Published var cfState: Tunnel.State = .stopped
    @Published var cfSteps: [SetupStep] = []
    var cfRunner: Process?
    var cfWanted = false

    let tunnel = Tunnel()
    private var runners: [UUID: ProcessRunner] = [:]
    private var restartBlocked: Set<UUID> = []
    private var timers: [Timer] = []
    private var started = false
    var pendingSync = false
    @Published var wildcardStatus: [String: Check] = [:]
    let web = WebDashboard()
    @Published var webState: WebDashboard.State = .stopped
    /// Bumped after /etc/hosts changes so the Hosts page re-reads it.
    @Published var hostsVersion = 0
    var hostsDeclined = ""

    init() {
        config = ConfigFile.load()
        tunnel.onState = { [weak self] state in Task { @MainActor in self?.tunnelState = state } }
        tunnel.onLog = { [weak self] line, isError in Task { @MainActor in self?.log("Tunnel", line, error: isError) } }
        proxy.onState = { [weak self] st in Task { @MainActor in
            self?.proxyState = st
            if case .failed(let m) = st { self?.log("Proxy", m, error: true) }
        } }
        proxy.onHTTPSState = { [weak self] st in Task { @MainActor in
            self?.httpsState = st
            self?.syncProxyRoutes()
            if case .failed(let m) = st { self?.log("HTTPS", m, error: true) }
        } }
        proxy.onRequest = { [weak self] _, host, line, _ in
            if host == "acme" { Task { @MainActor in self?.log("HTTPS", line) } }
        }
    }

    /// Relay mode: server set up. (Other modes: see isReady.)
    var isSetUp: Bool { config.serverMode != nil && config.server.isComplete }
    var tunnelUp: Bool { if case .connected = tunnelState { return true } else { return false } }

    /// Called once when the UI first appears.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        applyAppearance()
        if Demo.on { Demo.fill(self); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        for service in config.services where service.autoStart && service.hasCommand { startCommand(service) }
        applyKeepAwake()
        if config.autoConnect { startMode() }
        startWebDashboard()
        Task {
            await refreshNetwork()
            await refreshAll()
            await checkAllWildcards()
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            let model = self
            Task { @MainActor in await model?.refreshPorts() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            let model = self
            Task { @MainActor in
                await model?.refreshNetwork()
                await model?.refreshOnline()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            let model = self
            Task { @MainActor in if model?.config.mode == .staticIP { await model?.ensureStaticCertificate() } }
        })
    }

    // MARK: - SSH keys

    /// Private keys in ~/.ssh that have a matching .pub.
    var sshKeys: [String] {
        let dir = (("~/.ssh") as NSString).expandingTildeInPath
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".pub") }.map { "~/.ssh/" + $0.dropLast(4) }.sorted()
    }

    func publicKey() -> String {
        (try? String(contentsOfFile: config.server.expandedKeyPath + ".pub", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Keys in ~/.ssh with their public line and the user name in it.
    var sshKeyInfos: [SSHKeyInfo] {
        sshKeys.compactMap { path in
            let full = (path as NSString).expandingTildeInPath + ".pub"
            guard let line = try? String(contentsOfFile: full, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
            return SSHKeyInfo(path: path, publicKey: line)
        }
    }

    nonisolated static func validUserName(_ s: String) -> Bool {
        s.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }

    /// New ed25519 key whose comment is `user`: Google Cloud creates that
    /// user on the VM when the key is added. Selects it and fills SSH user.
    @discardableResult
    func createKey(user: String) -> String? {
        let user = user.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.validUserName(user) else {
            return "Use small letters, numbers, - or _ (for example: faiyaz)."
        }
        var name = "ontutunnel_\(user)_ed25519"
        var n = 2
        while FileManager.default.fileExists(atPath: (("~/.ssh/" + name) as NSString).expandingTildeInPath) {
            name = "ontutunnel_\(user)_\(n)_ed25519"; n += 1
        }
        let path = (("~/.ssh/" + name) as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", user, "-f", path])
        guard FileManager.default.fileExists(atPath: path + ".pub") else { return "Couldn't create the key." }
        config.server.keyPath = "~/.ssh/" + name
        config.server.user = user
        log("Server", "New SSH key ~/.ssh/\(name) for user \(user) — add its public key to the server.")
        return nil
    }

    // MARK: - Server

    func testConnection() async {
        guard config.server.isComplete else { connection = .failed("Enter the server IP and user."); return }
        connection = .checking
        let (r, f) = await RemoteServer.probe(config.server)
        if let f {
            facts = f
            connection = f.sudo ? .ok : .warning("Connected, but this user can't use sudo without a password.")
            serverIP = await Task.detached { [host = config.server.host] in DNSLookup.resolveHost(host) }.value
            log("Server", "Connected to \(config.server.host) — \(f.os), \(f.arch)")
        } else {
            connection = .failed(Self.explainSSH(r.message))
            log("Server", "SSH failed: \(r.message)", error: true)
        }
    }

    static func explainSSH(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("permission denied") { return "The server refused the SSH key. Add the public key shown below to the server, then test again." }
        if m.contains("timed out") || m.contains("no route") { return "No answer from the server — check the IP, that the server is running, and that port 22 is open." }
        if m.contains("could not resolve") { return "Server name not found — check the IP or host name." }
        if m.contains("no such file") && m.contains("identity") { return "SSH key file not found — choose a key or create one." }
        return message.isEmpty ? "SSH failed." : message
    }

    private func step(_ index: Int, _ state: Check, _ detail: String = "") {
        guard steps.indices.contains(index) else { return }
        steps[index].state = state
        steps[index].detail = detail
    }

    /// "Set up server": check, install what's missing, publish, connect.
    func setupServer() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        steps = ["Connect over SSH", "Admin rights (sudo)", "Ports 80/443 on the server", "SSH tunnels allowed",
                 "Web server for your sites", "Pick free tunnel ports", "Publish your sites", "Start the tunnel",
                 "Check from the internet"].map { SetupStep(title: $0) }

        step(0, .checking)
        let (r, f) = await RemoteServer.probe(config.server)
        guard let f else { step(0, .failed(Self.explainSSH(r.message))); connection = .failed(Self.explainSSH(r.message)); return }
        facts = f
        connection = .ok
        serverIP = await Task.detached { [host = config.server.host] in DNSLookup.resolveHost(host) }.value
        step(0, .ok, "\(f.os) · \(f.arch)")

        guard f.sudo else {
            step(1, .failed("User \(config.server.user) needs passwordless sudo. On GCP the default user has it; otherwise run `sudo visudo` and add: \(config.server.user) ALL=(ALL) NOPASSWD:ALL"))
            return
        }
        step(1, .ok)

        let mode: ServerMode
        switch f.plan {
        case .use(let m):
            mode = m
            step(2, .ok, m == .caddy
                 ? (f.ourCaddy ? "OntuTunnel's own Caddy is already running" : "Free — OntuTunnel will run its own Caddy")
                 : "nginx already uses them — OntuTunnel will only add its own files next to your sites")
        case .blocked(let why):
            step(2, .failed(why)); return
        }

        step(3, f.forwarding == "no" ? .failed("AllowTcpForwarding is off in /etc/ssh/sshd_config — set it to yes and restart ssh.") : .ok)
        if f.forwarding == "no" { return }

        step(4, .checking)
        if mode == .caddy {
            let install = await RemoteServer.run(config.server, RemoteServer.installCaddyScript(), timeout: 300)
            guard install.ok else { step(4, .failed("Installing Caddy failed: \(install.message)")); return }
            step(4, .ok, "Own Caddy at /opt/ontutunnel (service ontutunnel-caddy) — " +
                 (install.out.split(separator: "\n").last.map(String.init) ?? ""))
        } else {
            step(4, .ok, "Existing nginx — new files only: /etc/nginx/conf.d/ontutunnel-*.conf")
        }
        config.serverMode = mode

        assignPorts(used: f.usedPorts)
        step(5, .ok, config.services.filter(\.enabled).map { "\($0.normalizedDomain) → server 127.0.0.1:\($0.remotePort)" }.joined(separator: ", "))

        step(6, .checking)
        let applied = await applyConfig()
        step(6, applied.0 ? (applied.1.isEmpty ? .ok : .warning(applied.1)) : .failed(applied.1))
        guard applied.0 else { return }

        step(7, .checking)
        connectTunnel()
        for _ in 0..<12 where !tunnelUp {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if tunnelUp { step(7, .ok) } else if case .failed(let why) = tunnelState { step(7, .failed(why)) } else { step(7, .warning("Still connecting…")) }

        step(8, .checking)
        await refreshOnline()
        let live = config.services.filter(\.enabled).map { status(of: $0).live }
        if live.isEmpty { step(8, .warning("Add a service to publish your first site.")) }
        else if live.allSatisfy(\.isOK) { step(8, .ok, "Your sites answer over HTTPS") }
        else { step(8, .warning("Not live yet — see each service on the Dashboard (usually DNS still pointing elsewhere, or the certificate is being issued; takes a minute after DNS is right).")) }
        notify("OntuTunnel server ready", config.server.host)
    }

    /// Give every enabled service a random free port on the server.
    private func assignPorts(used: Set<Int>) {
        var taken = used
        for s in config.services { taken.insert(s.remotePort); taken.insert(s.remoteSocketPort) }
        for i in config.services.indices {
            if config.services[i].remotePort == 0 || used.contains(config.services[i].remotePort) {
                taken.remove(config.services[i].remotePort)
                config.services[i].remotePort = RemoteServer.freePort(avoiding: taken)
                taken.insert(config.services[i].remotePort)
            }
            if config.services[i].socketPort > 0 {
                if config.services[i].remoteSocketPort == 0 || used.contains(config.services[i].remoteSocketPort) {
                    config.services[i].remoteSocketPort = RemoteServer.freePort(avoiding: taken)
                    taken.insert(config.services[i].remoteSocketPort)
                }
            } else {
                config.services[i].remoteSocketPort = 0
            }
        }
    }

    /// Write the site config on the server. Returns (ok, message).
    private func applyConfig() async -> (Bool, String) {
        guard let mode = config.serverMode else { return (false, "Server not set up yet.") }
        let script = mode == .caddy
            ? RemoteServer.applyCaddyScript(config.services, email: config.server.email)
            : RemoteServer.applyNginxScript(config.services, email: config.server.email, published: config.published)
        let r = await RemoteServer.run(config.server, script, timeout: 240)
        for line in r.out.split(separator: "\n") where line.hasPrefix("CERT-") {
            log("Server", String(line), error: line.hasPrefix("CERT-PENDING"))
        }
        if !r.ok {
            log("Server", "Publishing failed: \(r.message)", error: true)
            return (false, r.message)
        }
        let pending = r.out.split(separator: "\n").filter { $0.hasPrefix("CERT-PENDING") }
        let message = pending.isEmpty ? "" : "HTTPS pending for some domains (DNS must point to \(serverIP.isEmpty ? config.server.host : serverIP) first) — Sync again after fixing DNS."
        config.published = config.services
            .filter { $0.enabled && $0.remotePort > 0 && !$0.normalizedDomain.isEmpty }
            .map(\.normalizedDomain)
        log("Server", "Published \(config.services.filter(\.enabled).count) site(s) (\(mode.rawValue))")
        return (true, message)
    }

    /// After adding/editing/removing services: new ports, config, tunnel.
    /// A change made while a sync is running is synced right after it.
    func sync() async {
        guard isSetUp else { return }
        if busy { pendingSync = true; return }
        busy = true
        defer {
            busy = false
            if pendingSync {
                pendingSync = false
                Task { await self.sync() }
            }
        }
        syncMessage = "Syncing…"
        let needPorts = config.services.contains { $0.enabled && ($0.remotePort == 0 || ($0.socketPort > 0 && $0.remoteSocketPort == 0)) }
        if needPorts {
            let (_, f) = await RemoteServer.probe(config.server)
            guard let f else { syncMessage = "Can't reach the server."; return }
            facts = f
            assignPorts(used: f.usedPorts)
        }
        let (ok, message) = await applyConfig()
        if ok { connectTunnel() }
        syncMessage = ok ? (message.isEmpty ? "Synced at \(Date().formatted(date: .omitted, time: .shortened))." : message) : "Sync failed: \(message)"
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await refreshOnline()
    }

    func connectTunnel() {
        let forwards = config.services.filter { $0.enabled && $0.remotePort > 0 }.flatMap { s -> [(remote: Int, local: Int)] in
            var f = [(remote: s.remotePort, local: s.localPort)]
            if s.socketPort > 0 && s.remoteSocketPort > 0 { f.append((remote: s.remoteSocketPort, local: s.socketPort)) }
            return f
        }
        tunnel.start(server: config.server, forwards: forwards)
    }

    func disconnectTunnel() { tunnel.stop() }

    func removeFromServer() async {
        busy = true
        defer { busy = false }
        tunnel.stop()
        let r = await RemoteServer.run(config.server, RemoteServer.uninstallScript(config.serverMode))
        if r.ok {
            config.serverMode = nil
            for i in config.services.indices { config.services[i].remotePort = 0; config.services[i].remoteSocketPort = 0 }
            steps = []
            log("Server", "Removed everything OntuTunnel had added to \(config.server.host).")
        } else {
            log("Server", "Remove failed: \(r.message)", error: true)
        }
    }

    // MARK: - Services

    func binding(for id: UUID) -> Service? { config.services.first { $0.id == id } }
    func status(of service: Service) -> ServiceStatus { status[service.id] ?? ServiceStatus() }

    func save(_ service: Service) {
        var s = service
        s.domain = s.normalizedDomain
        s.frappeSite = s.frappeSite.trimmingCharacters(in: .whitespaces)
        guard s.isSafe else {
            log("Services", "Not saved: \(s.domain) — use only letters, numbers, - and . in the domain and Frappe site", error: true)
            return
        }
        if let i = config.services.firstIndex(where: { $0.id == s.id }) {
            if config.services[i].socketPort != s.socketPort { s.remoteSocketPort = 0 }
            config.services[i] = s
        } else {
            config.services.append(s)
        }
        Task { await syncCurrentMode(); await refreshService(s) }
    }

    func delete(_ service: Service) {
        stopCommand(service)
        config.services.removeAll { $0.id == service.id }
        status[service.id] = nil
        Task { await syncCurrentMode() }
    }

    func setEnabled(_ service: Service, _ on: Bool) {
        var s = service
        s.enabled = on
        save(s)
    }

    func publicURL(_ service: Service) -> URL? { URL(string: "https://\(service.normalizedDomain)") }

    // MARK: - Start commands

    func startCommand(_ service: Service) {
        guard service.hasCommand else { return }
        let runner = runners[service.id] ?? ProcessRunner(serviceName: service.name)
        runners[service.id] = runner
        restartBlocked.remove(service.id)
        runner.onOutput = { [weak self] line, isError in Task { @MainActor in self?.log(service.name, line, error: isError) } }
        runner.onExit = { [weak self] code, requested in Task { @MainActor in self?.commandExited(service.id, code: code, requested: requested) } }
        do {
            try runner.start(command: service.startCommand, directory: service.workingDirectory)
            setProcess(service.id, .running)
            log(service.name, "$ \(service.startCommand)")
        } catch {
            setProcess(service.id, .crashed(-1))
            log(service.name, "Could not start: \(error.localizedDescription)", error: true)
        }
    }

    func stopCommand(_ service: Service) {
        restartBlocked.insert(service.id)
        runners[service.id]?.stop()
    }

    func isCommandRunning(_ service: Service) -> Bool { runners[service.id]?.isRunning ?? false }

    private func commandExited(_ id: UUID, code: Int32, requested: Bool) {
        guard let service = binding(for: id) else { return }
        setProcess(id, requested ? .stopped : .crashed(code))
        log(service.name, requested ? "Stopped" : "Exited with code \(code)", error: !requested)
        if !requested && service.keepAlive && !restartBlocked.contains(id) {
            log(service.name, "Keep alive: restarting in 3 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let current = self.binding(for: id), !self.restartBlocked.contains(id) else { return }
                self.startCommand(current)
            }
        } else if !requested {
            notify("\(service.name) stopped", "Its start command exited with code \(code).")
        }
    }

    private func setProcess(_ id: UUID, _ state: ProcessState) {
        var st = status[id] ?? ServiceStatus()
        st.process = state
        status[id] = st
    }

    // MARK: - Checks

    func refreshAll() async {
        if Demo.on { return }
        await refreshPorts()
        await refreshOnline()
    }

    func refreshPorts() async {
        if Demo.on { return }
        for service in config.services {
            let open = await PortProbe.isOpen(service.localPort)
            var st = status[service.id] ?? ServiceStatus()
            if st.port == .open && !open { log(service.name, "localhost:\(service.localPort) stopped answering", error: true) }
            st.port = open ? .open : .closed
            if service.hasCommand, st.process == .none { st.process = .stopped }
            status[service.id] = st
        }
    }

    /// DNS (A record → server) and end-to-end HTTPS for every service.
    func refreshOnline() async {
        if Demo.on { return }
        if serverIP.isEmpty, config.server.isComplete {
            serverIP = await Task.detached { [host = config.server.host] in DNSLookup.resolveHost(host) }.value
        }
        for service in config.services where service.enabled { await refreshService(service) }
    }

    private func refreshService(_ service: Service) async {
        let domain = service.normalizedDomain
        guard !domain.isEmpty else { return }
        var st = status[service.id] ?? ServiceStatus()
        st.live = .checking
        status[service.id] = st
        let a = await Task.detached { DNSLookup.a(domain) }.value
        let ip = serverIP
        st = status[service.id] ?? ServiceStatus()
        st.dnsA = a
        let target = config.mode == .staticIP ? staticTargetIP : ip
        if config.mode == .cloudflare {
            st.dns = config.cloudflare.routed.contains(domain) ? .ok
                : .warning("Not routed yet — click Sync now")
        } else if a.isEmpty { st.dns = .failed("No A record") }
        else if !target.isEmpty && a == [target] { st.dns = .ok }
        else { st.dns = .warning("Points to \(a.joined(separator: ", "))") }
        st.live = isReady ? await LiveCheck.check(domain) : .unknown
        if config.mode == .staticIP, case .failed = st.live {
            st.live = .warning("Can't test from inside your home network — open it on your phone (mobile data)")
        }
        st.liveCheckedAt = Date()
        status[service.id] = st
    }

    // MARK: - Settings, logs, notifications

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Settings", "Launch at login: \(error.localizedDescription)", error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shutdown() {
        for (_, runner) in runners { runner.stop() }
        stopAllModes()
    }

    static let logFile: URL = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OntuTunnel.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        return url
    }()

    func log(_ source: String, _ text: String, error: Bool = false) {
        logs.append(LogLine(source: source, text: text, isError: error))
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
        if let h = try? FileHandle(forWritingTo: Self.logFile) {
            h.seekToEndOfFile()
            h.write(Data("\(ISO8601DateFormatter().string(from: Date())) [\(source)]\(error ? " ERROR" : "") \(text)\n".utf8))
            try? h.close()
        }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    enum Health { case good, warning, bad, idle }

    var health: Health {
        let active = config.services.filter(\.enabled)
        if active.isEmpty || !isReady { return .idle }
        if !isConnected { return .bad }
        if active.contains(where: { status(of: $0).port == .closed }) { return .bad }
        if active.contains(where: { !status(of: $0).live.isOK }) { return .warning }
        return .good
    }
}
