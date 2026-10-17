import Foundation
import Network

/// Browser dashboard: the same status and buttons as the app, served by
/// OntuTunnel itself at http://localhost:<port> (default 7777).
/// Only this Mac can open it unless "allow other devices" is on; then every
/// request needs the access key (?key=… once, then a cookie).
final class WebDashboard {
    enum State: Equatable { case stopped, listening(Int), failed(String) }

    private let queue = DispatchQueue(label: "ontutunnel.web")
    private var listener: NWListener?
    private var key = ""
    private var lan = false
    var onState: ((State) -> Void)?
    /// (method, path, body) → (status, content type, body); called on the main actor.
    var handler: (@MainActor (String, String, Data) async -> (Int, String, Data))?

    func start(port: Int, allowLAN: Bool, accessKey: String) {
        stop()
        lan = allowLAN
        key = accessKey
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !allowLAN { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort) }
        do {
            let l = allowLAN ? try NWListener(using: params, on: nwPort) : try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready: self?.onState?(.listening(port))
                case .failed(let e): self?.onState?(.failed(e.localizedDescription)); l.cancel()
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            onState?(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onState?(.stopped)
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { c.cancel(); return }
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buffer.prefix(upTo: range.lowerBound), encoding: .utf8) ?? ""
                    let length = head.split(separator: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                    let body = buffer.suffix(from: range.upperBound)
                    if body.count >= length || done || error != nil {
                        self.handle(c, head: head, body: Data(body.prefix(length)))
                        return
                    }
                }
                if done || error != nil || buffer.count > 1_000_000 { c.cancel(); return }
                read()
            }
        }
        read()
    }

    private func handle(_ c: NWConnection, head: String, body: Data) {
        let lines = head.split(separator: "\r\n").map(String.init)
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        guard parts.count >= 2 else { c.cancel(); return }
        let method = parts[0]
        var path = parts[1]
        var query: [String: String] = [:]
        if let q = path.firstIndex(of: "?") {
            for pair in path[path.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
            path = String(path[..<q])
        }

        // access key when reachable from other devices
        var setCookie = ""
        if lan {
            let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") } ?? ""
            let hasCookie = cookie.contains("lbkey=\(key)")
            if query["key"] == key { setCookie = "Set-Cookie: lbkey=\(key); Path=/; HttpOnly; SameSite=Strict\r\n" }
            else if !hasCookie {
                respond(c, 401, "text/html; charset=utf-8",
                        Data("<!doctype html><meta name=viewport content='width=device-width'><body style='font:16px -apple-system,sans-serif;padding:40px'><h2>OntuTunnel</h2><p>Open the link with the access key from OntuTunnel → Settings → Browser dashboard.</p></body>".utf8), extra: "")
                return
            }
        }

        let extra = setCookie
        let route = path
        Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else { c.cancel(); return }
            let (status, type, data) = await handler(method, route, body)
            self.queue.async { self.respond(c, status, type, data, extra: extra) }
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ type: String, _ data: Data, extra: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "OK"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n".utf8)
        out.append(data)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - API on the app model

@MainActor
extension AppModel {
    func startWebDashboard() {
        web.onState = { [weak self] st in Task { @MainActor in self?.webState = st } }
        web.handler = { [weak self] method, path, body in
            guard let self else { return (500, "text/plain", Data()) }
            return await self.webRequest(method, path, body)
        }
        if config.web.key.isEmpty { config.web.key = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() }
        if config.web.enabled { web.start(port: config.web.port, allowLAN: config.web.allowLAN, accessKey: config.web.key) }
        else { web.stop() }
    }

    var webURL: String {
        let host = config.web.allowLAN && !network.localIPv4.isEmpty ? network.localIPv4 : "localhost"
        return "http://\(host):\(config.web.port)" + (config.web.allowLAN ? "/?key=\(config.web.key)" : "")
    }

    private func checkJSON(_ c: Check) -> [String: Any] {
        ["ok": c.isOK, "state": { switch c { case .ok: return "ok"; case .warning: return "warning"; case .failed: return "failed"; case .checking: return "checking"; case .unknown: return "unknown" } }(), "text": c.isOK ? "OK" : c.text]
    }

    func webRequest(_ method: String, _ path: String, _ body: Data) async -> (Int, String, Data) {
        if method == "GET" && (path == "/" || path == "/index.html") {
            return (200, "text/html; charset=utf-8", Data(WebPage.html.utf8))
        }
        if method == "GET" && path == "/api/status" {
            let hidden = Set(config.hiddenPorts)
            let published = Set(config.services.map(\.localPort))
            let services: [[String: Any]] = config.services.map { s in
                let st = status(of: s)
                return ["id": s.id.uuidString, "name": s.name, "domain": s.normalizedDomain, "localPort": s.localPort,
                        "frappeSite": s.frappeSite, "enabled": s.enabled, "hasCommand": s.hasCommand,
                        "commandRunning": isCommandRunning(s),
                        "port": st.port == .open ? "open" : st.port == .closed ? "closed" : "unknown",
                        "dns": checkJSON(st.dns), "live": checkJSON(st.live), "url": "https://\(s.normalizedDomain)"]
            }
            let json: [String: Any] = [
                "mode": config.mode.rawValue, "modeTitle": config.mode.title, "ready": isReady, "connected": isConnected,
                "busy": busy, "dnsTarget": dnsTarget, "syncMessage": syncMessage,
                "server": ["host": config.server.host, "ip": serverIP],
                "network": ["publicIPv4": network.publicIPv4, "localIPv4": network.localIPv4, "ipv6": network.ipv6, "router": network.router],
                "services": services,
                "ports": localPorts.map { ["port": $0.port, "process": $0.process, "hidden": hidden.contains($0.port), "published": published.contains($0.port)] },
                "wildcards": config.wildcardBases.map { ["base": $0, "check": checkJSON(wildcardStatus[$0] ?? .unknown)] },
                "logs": logs.suffix(40).map { ["time": $0.date.formatted(date: .omitted, time: .standard), "source": $0.source, "text": $0.text, "error": $0.isError] },
            ]
            return (200, "application/json", (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        }
        if method == "POST" && path == "/api/action" {
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let action = obj["action"] as? String else { return (400, "application/json", Data("{\"error\":\"bad request\"}".utf8)) }
            let service = (obj["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap { binding(for: $0) }
            switch action {
            case "toggle": if let s = service { setEnabled(s, obj["on"] as? Bool ?? !s.enabled) }
            case "start": if let s = service { startCommand(s) }
            case "stop": if let s = service { stopCommand(s) }
            case "delete": if let s = service { delete(s) }
            case "sync": Task { await syncCurrentMode() }
            case "connect": startMode()
            case "disconnect": stopAllModes()
            case "refresh": Task { await refreshNetwork(); await refreshAll(); await checkAllWildcards() }
            case "hide": if let p = obj["port"] as? Int, !config.hiddenPorts.contains(p) { config.hiddenPorts.append(p) }
            case "unhide": if let p = obj["port"] as? Int { config.hiddenPorts.removeAll { $0 == p } }
            case "add":
                let domain = (obj["domain"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let port = obj["localPort"] as? Int ?? Int(obj["localPort"] as? String ?? "") ?? 0
                guard domain.contains("."), (1...65535).contains(port) else {
                    return (400, "application/json", Data("{\"error\":\"Enter a full domain and a port.\"}".utf8))
                }
                var s = Service(name: obj["name"] as? String ?? "", domain: domain, localPort: port)
                s.frappeSite = obj["frappeSite"] as? String ?? ""
                save(s)
            default: return (400, "application/json", Data("{\"error\":\"unknown action\"}".utf8))
            }
            return (200, "application/json", Data("{\"ok\":true}".utf8))
        }
        return (404, "text/plain", Data("Not found".utf8))
    }
}
