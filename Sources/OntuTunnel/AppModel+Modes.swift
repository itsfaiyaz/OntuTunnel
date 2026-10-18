import AppKit
import CryptoKit
import Foundation

/// Connection modes: relay server (SSH), own static IP, Cloudflare Tunnel.
@MainActor
extension AppModel {

    // MARK: - Common

    /// Ready to publish in the chosen mode.
    var isReady: Bool {
        switch config.mode {
        case .relay: return isSetUp
        case .staticIP: return true
        case .cloudflare: return !config.cloudflare.tunnelID.isEmpty
        }
    }

    /// The link to the internet is up right now.
    var isConnected: Bool {
        switch config.mode {
        case .relay: return tunnelUp
        case .staticIP: if case .listening = proxyState { return true } else { return false }
        case .cloudflare: if case .connected = cfState { return true } else { return false }
        }
    }

    var httpsRunning: Bool { if case .listening = httpsState { return true } else { return false } }

    /// Where an A record must point (relay / static IP); empty for Cloudflare.
    var dnsTarget: String {
        switch config.mode {
        case .relay: return serverIP
        case .staticIP: return staticTargetIP
        case .cloudflare: return ""
        }
    }

    var staticTargetIP: String {
        let manual = config.staticIP.ip.trimmingCharacters(in: .whitespaces)
        return manual.isEmpty ? network.publicIPv4 : manual
    }

    func setMode(_ mode: ConnectionMode) {
        guard mode != config.mode else { return }
        stopAllModes()
        config.mode = mode
        log("Connection", "Switched to \(mode.title)")
        startMode()
        if mode != .staticIP { Task { await syncHosts() } }   // removes OntuTunnel's hosts entries
    }

    func startMode() {
        switch config.mode {
        case .relay:
            if isSetUp {
                connectTunnel()
                // make the server match the current settings (fixes drift)
                Task { await sync() }
            }
        case .staticIP:
            startStatic()
            Task { await syncHosts() }
        case .cloudflare: if isReady { startCloudflare() }
        }
    }

    func stopAllModes() {
        tunnel.stop()
        proxy.stop()
        proxy.stopHTTPS()
        stopCloudflared()
    }

    func syncCurrentMode() async {
        switch config.mode {
        case .relay: await sync()
        case .staticIP:
            syncProxyRoutes()
            await syncHosts()
            await ensureStaticCertificate()
        case .cloudflare: await syncCloudflare()
        }
    }

    func refreshNetwork() async {
        if Demo.on { return }
        network = await NetworkInfo.snapshot()
        localPorts = await Task.detached { LocalPorts.scan() }.value
    }

    /// Routes for OntuTunnel's own proxy (static IP / Cloudflare modes).
    func syncProxyRoutes() {
        let httpsOn = { if case .listening = self.httpsState { return true } else { return false } }()
        proxy.setRedirect(config.mode == .staticIP && config.staticIP.httpsEnabled && config.staticIP.redirectToHTTPS, httpsPort: 443)
        var routes: [String: Route] = [:]
        for s in config.services where s.enabled && !s.normalizedDomain.isEmpty {
            var r = Route(serviceID: s.id, localPort: s.localPort, frappeSite: s.frappeSite.trimmingCharacters(in: .whitespaces),
                          hostOverride: "", httpsAvailable: httpsOn && (certificate?.covers(s.normalizedDomain) ?? false))
            r.socketPort = s.socketPort
            routes[s.normalizedDomain] = r
        }
        proxy.updateRoutes(routes)
    }

    // MARK: - Static IP

    func startStatic() {
        proxy.assumeHTTPS = false
        syncProxyRoutes()
        proxy.start(port: 80)
        certificate = CertificateStore.load()
        startStaticHTTPS()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await ensureStaticCertificate()
        }
    }

    func startStaticHTTPS() {
        guard config.staticIP.httpsEnabled, let cert = certificate, cert.notAfter > Date() else {
            proxy.stopHTTPS(); syncProxyRoutes(); return
        }
        do {
            proxy.startHTTPS(port: 443, identity: try CertificateStore.identity(for: cert))
        } catch {
            certMessage = error.localizedDescription
            log("HTTPS", error.localizedDescription, error: true)
        }
    }

    /// Let's Encrypt (HTTP check through port 80) for every enabled domain.
    func ensureStaticCertificate(force: Bool = false) async {
        guard config.mode == .staticIP, config.staticIP.httpsEnabled, !certBusy else { return }
        // only domains whose DNS already points to this connection's IP
        let target = staticTargetIP
        let candidates = config.services.filter { $0.enabled && $0.normalizedDomain.contains(".") }.map(\.normalizedDomain)
        var names: [String] = []
        for d in candidates where await Task.detached(operation: { DNSLookup.a(d) }).value.contains(target) { names.append(d) }
        guard !names.isEmpty else {
            if !candidates.isEmpty { certMessage = "Waiting for DNS: point the A records to \(target.isEmpty ? "your static IP" : target), then click Get certificate." }
            return
        }
        if !force, let c = certificate, Set(names).isSubset(of: Set(c.names)), c.daysLeft > 30 {
            if case .listening = httpsState {} else { startStaticHTTPS() }
            return
        }
        guard case .listening = proxyState else {
            certMessage = "Port 80 must be open on this Mac first (see the proxy status)."
            return
        }
        certBusy = true
        defer { certBusy = false }
        do {
            let accountKey: P256.Signing.PrivateKey
            if let raw = Keychain.get(SecretKey.acmeAccountKey(staging: false)),
               let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
                accountKey = key
            } else {
                accountKey = P256.Signing.PrivateKey()
                Keychain.set(SecretKey.acmeAccountKey(staging: false), accountKey.rawRepresentation)
                Keychain.set(SecretKey.acmeKid(staging: false), "")
            }
            let kid = Keychain.string(SecretKey.acmeKid(staging: false))
            let client = ACMEClient(staging: false, accountKey: accountKey, kid: kid.isEmpty ? nil : kid) { [weak self] m in
                Task { @MainActor in self?.certMessage = m; self?.log("HTTPS", m) }
            }
            let proxy = self.proxy
            let certKey = P256.Signing.PrivateKey()
            let pem = try await client.issue(names: names, email: config.staticIP.email,
                                             mode: .http(publish: { proxy.setChallenge($0, $1) }, remove: { proxy.setChallenge($0, nil) }),
                                             certKey: certKey)
            if let kid = client.kid { Keychain.set(SecretKey.acmeKid(staging: false), kid) }
            certificate = try CertificateStore.save(names: names, key: certKey, chainPEM: pem)
            certMessage = "Certificate valid until \(certificate!.notAfter.formatted(date: .abbreviated, time: .omitted))."
            startStaticHTTPS()
        } catch {
            certMessage = error.localizedDescription
            log("HTTPS", error.localizedDescription, error: true)
        }
    }

    // MARK: - Cloudflare Tunnel

    private func cfStep(_ i: Int, _ state: Check, _ detail: String = "") {
        guard cfSteps.indices.contains(i) else { return }
        cfSteps[i].state = state
        cfSteps[i].detail = detail
    }

    /// Install → login (once) → tunnel → DNS routes → run.
    func setupCloudflare() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        cfSteps = ["Install cloudflared", "Log in to Cloudflare (browser, once)", "Create the tunnel",
                   "Local proxy for your sites", "DNS records in Cloudflare", "Start the tunnel", "Check from the internet"]
            .map { SetupStep(title: $0) }

        cfStep(0, .checking)
        let bin: String
        switch await Cloudflare.install() {
        case .success(let b): bin = b; cfStep(0, .ok, b)
        case .failure(let e): cfStep(0, .failed(e.message)); return
        }

        cfStep(1, .checking, Cloudflare.isLoggedIn ? "" : "A Cloudflare page opened in your browser — choose your domain there and click Authorize.")
        if !Cloudflare.isLoggedIn {
            let r = await Cloudflare.login(bin)
            guard Cloudflare.isLoggedIn else { cfStep(1, .failed("Login not finished: \(String(r.text.suffix(300)))")); return }
        }
        cfStep(1, .ok, "Logged in (~/.cloudflared/cert.pem)")

        cfStep(2, .checking)
        if config.cloudflare.tunnelName.isEmpty {
            let host = (Host.current().localizedName ?? "mac").lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            config.cloudflare.tunnelName = "ontutunnel-\(host)"
        }
        switch await Cloudflare.ensureTunnel(bin, name: config.cloudflare.tunnelName) {
        case .success(let id): config.cloudflare.tunnelID = id; cfStep(2, .ok, "\(config.cloudflare.tunnelName) · \(id)")
        case .failure(let e): cfStep(2, .failed(e.message)); return
        }

        cfStep(3, .checking)
        if config.cloudflare.proxyPort == 0 { config.cloudflare.proxyPort = Int.random(in: 41000...48999) }
        do { try Cloudflare.writeConfig(tunnelID: config.cloudflare.tunnelID, proxyPort: config.cloudflare.proxyPort) }
        catch { cfStep(3, .failed(error.localizedDescription)); return }
        startCloudflareProxy()
        cfStep(3, .ok, "127.0.0.1:\(config.cloudflare.proxyPort) — only cloudflared on this Mac can reach it")

        cfStep(4, .checking)
        let failed = await routeCloudflareDNS(bin)
        cfStep(4, failed.isEmpty ? .ok : .warning(failed.joined(separator: "; ")),
               config.cloudflare.routed.isEmpty ? "Add a service to create its record" : config.cloudflare.routed.joined(separator: ", "))

        cfStep(5, .checking)
        startCloudflared(bin)
        for _ in 0..<20 {
            if case .connected = cfState { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if case .connected = cfState { cfStep(5, .ok) } else if case .failed(let w) = cfState { cfStep(5, .failed(w)) } else { cfStep(5, .warning("Still connecting…")) }

        cfStep(6, .checking)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await refreshOnline()
        let live = config.services.filter(\.enabled).map { status(of: $0).live }
        cfStep(6, live.isEmpty ? .warning("Add a service to publish your first site.")
               : live.allSatisfy(\.isOK) ? .ok : .warning("Not live yet — DNS can take a minute; press Refresh on the Dashboard."))
    }

    /// Returns error messages for domains that could not be routed.
    func routeCloudflareDNS(_ bin: String) async -> [String] {
        var errors: [String] = []
        let wanted = config.services.filter { $0.enabled && $0.normalizedDomain.contains(".") }.map(\.normalizedDomain)
        for d in wanted where !config.cloudflare.routed.contains(d) {
            let r = await Cloudflare.routeDNS(bin, tunnelID: config.cloudflare.tunnelID, domain: d)
            if r.code == 0 || r.text.lowercased().contains("already") {
                config.cloudflare.routed.append(d)
                log("Cloudflare", "DNS: \(d) → tunnel")
            } else {
                let why = r.text.contains("not found") || r.text.contains("zone")
                    ? "\(d): its domain isn't in the Cloudflare account you logged in with"
                    : "\(d): \(String(r.text.suffix(200)))"
                errors.append(why)
                log("Cloudflare", why, error: true)
            }
        }
        return errors
    }

    func syncCloudflare() async {
        guard isReady, let bin = Cloudflare.binary() else { return }
        syncProxyRoutes()
        let errors = await routeCloudflareDNS(bin)
        syncMessage = errors.isEmpty ? "Synced at \(Date().formatted(date: .omitted, time: .shortened))." : errors.joined(separator: "; ")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await refreshOnline()
    }

    func startCloudflareProxy() {
        proxy.stop()
        proxy.assumeHTTPS = true
        syncProxyRoutes()
        proxy.start(port: config.cloudflare.proxyPort, loopbackOnly: true)
    }

    func startCloudflare() {
        guard let bin = Cloudflare.binary() else { cfState = .failed("cloudflared not installed — run Set up"); return }
        try? Cloudflare.writeConfig(tunnelID: config.cloudflare.tunnelID, proxyPort: config.cloudflare.proxyPort)
        startCloudflareProxy()
        startCloudflared(bin)
    }

    /// Runs `cloudflared tunnel run`, restarting it if it exits.
    func startCloudflared(_ bin: String) {
        stopCloudflared()
        cfWanted = true
        launchCloudflared(bin, delay: 3)
    }

    private func launchCloudflared(_ bin: String, delay: TimeInterval) {
        guard cfWanted else { return }
        cfState = .connecting
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = Cloudflare.runArguments()
        let err = Pipe()
        task.standardError = err
        task.standardOutput = err
        task.standardInput = FileHandle.nullDevice
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let text = String(data: h.availableData, encoding: .utf8), !text.isEmpty else { return }
            let model = self
            Task { @MainActor in
                for line in text.split(whereSeparator: \.isNewline) {
                    let l = String(line)
                    if l.contains("Registered tunnel connection") { model?.cfState = .connected(Date()) }
                    if l.contains(" ERR ") || l.contains("error=") { model?.log("Cloudflare", l, error: true) }
                    else if l.contains("Registered tunnel connection") { model?.log("Cloudflare", l) }
                }
            }
        }
        task.terminationHandler = { [weak self] t in
            err.fileHandleForReading.readabilityHandler = nil
            let model = self
            Task { @MainActor in
                guard let self = model, self.cfWanted else { return }
                self.cfState = .failed("cloudflared exited (\(t.terminationStatus)) — restarting")
                self.log("Cloudflare", "cloudflared exited (\(t.terminationStatus)), restarting in \(Int(delay)) s", error: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.launchCloudflared(bin, delay: min(delay * 2, 60))
                }
            }
        }
        do {
            try task.run()
            cfRunner = task
        } catch {
            cfState = .failed(error.localizedDescription)
        }
    }

    func stopCloudflared() {
        cfWanted = false
        if let t = cfRunner, t.isRunning { t.terminationHandler = nil; t.terminate() }
        cfRunner = nil
        cfState = .stopped
    }

    /// Prefill a service from a port found on this Mac.
    func suggestedService(for port: ListeningPort) -> Service {
        var s = Service(name: port.process, domain: "", localPort: port.port)
        if port.process.lowercased().contains("python") || port.process.lowercased().contains("gunicorn") {
            s.name = "Frappe / Python on \(port.port)"
        } else if port.process.lowercased().contains("node") {
            s.name = "Node app on \(port.port)"
        }
        return s
    }

    // MARK: - Wildcard domains

    func addWildcard(_ raw: String) {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if base.hasPrefix("*.") { base.removeFirst(2) }
        guard base.contains("."), !config.wildcardBases.contains(base) else { return }
        config.wildcardBases.append(base)
        Task { await checkWildcard(base) }
    }

    func removeWildcard(_ base: String) {
        config.wildcardBases.removeAll { $0 == base }
        wildcardStatus[base] = nil
    }

    /// The wildcard works when a random name under it resolves to our IP.
    func checkWildcard(_ base: String) async {
        if Demo.on { return }
        wildcardStatus[base] = .checking
        let probe = "lb-check-\(Int.random(in: 100000...999999)).\(base)"
        let a = await Task.detached { DNSLookup.a(probe) }.value
        if config.mode == .cloudflare {
            wildcardStatus[base] = .ok        // Cloudflare creates each record itself
        } else if a.isEmpty {
            wildcardStatus[base] = .failed("No *.\(base) record yet")
        } else if !dnsTarget.isEmpty && a.contains(dnsTarget) {
            wildcardStatus[base] = .ok
        } else {
            wildcardStatus[base] = .warning("*.\(base) points to \(a.joined(separator: ", ")), not \(dnsTarget.isEmpty ? "this connection" : dnsTarget)")
        }
    }

    func checkAllWildcards() async {
        for b in config.wildcardBases { await checkWildcard(b) }
    }

    /// "*.dev" for base "dev.example.com" in zone "example.com" — what DNS panels ask for.
    static func wildcardRecordName(_ base: String) -> String {
        let label = DomainLabel.of(base)
        return label == "@" ? "*" : "*.\(label)"
    }
}

// MARK: - Hosts file

extension AppModel {
    /// "My static IP": keep OntuTunnel's block in /etc/hosts equal to the
    /// enabled sites (empty in other modes). Asks for the password only when
    /// something changes, and not again for the same list after a cancel.
    func syncHosts() async {
        var want: [String] = []
        if config.mode == .staticIP && !config.localHostsOff {
            want = config.services.filter { $0.enabled && HostsFile.isDomain($0.normalizedDomain) }
                .map(\.normalizedDomain).sorted()
        }
        let key = want.joined(separator: " ")
        let (rest, ours) = HostsFile.split(HostsFile.read())
        guard key != ours.sorted().joined(separator: " "), hostsDeclined != key else { return }
        let content = HostsFile.build(rest: rest, domains: want)
        do {
            try await Task.detached { try HostsFile.writeAsAdmin(content) }.value
            hostsDeclined = nil
            log("This Mac", want.isEmpty ? "Removed OntuTunnel's entries from /etc/hosts"
                : "Your sites now open from this Mac too (/etc/hosts: \(key) → 127.0.0.1)")
        } catch {
            hostsDeclined = key
            log("This Mac", "Couldn't update /etc/hosts: \(error.localizedDescription)", error: true)
        }
        hostsVersion += 1
    }

    /// One change on the Hosts page. Returns an error message, or nil.
    func editHosts(_ edit: HostsFile.Edit, ip: String = "", names: String = "") async -> String? {
        do {
            let content = try HostsFile.applying(edit, ip: ip, names: names)
            try await Task.detached { try HostsFile.writeAsAdmin(content) }.value
            log("Hosts", "Saved /etc/hosts")
            hostsVersion += 1
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
