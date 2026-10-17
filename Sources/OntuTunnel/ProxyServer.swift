import Foundation
import Network

/// Where a public host name goes.
struct Route {
    let serviceID: UUID
    let localPort: Int
    let frappeSite: String
    let hostOverride: String
    /// The current certificate covers this host name.
    let httpsAvailable: Bool
    /// Realtime (Socket.IO) port: /socket.io requests go here when set.
    var socketPort: Int = 0
}

/// Small HTTP reverse proxy: listens on the public port (80 by default, on
/// IPv4 and IPv6), picks the service by the Host header, and forwards the
/// connection to localhost:<port>.
///
/// Each request is sent upstream with `Connection: close`, so one TCP
/// connection carries one request and per-request routing stays correct.
/// WebSocket / Upgrade requests are passed through untouched after the
/// first request head (Frappe realtime, Next.js dev HMR).
final class ProxyServer {
    enum State: Equatable {
        case stopped
        case starting
        case listening(Int)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "ontutunnel.proxy")
    private var listener: NWListener?
    private var tlsListener: NWListener?
    private var routes: [String: Route] = [:]
    private let routesLock = NSLock()
    private var redirect = (enabled: false, httpsPort: 443)
    /// Behind Cloudflare: visitors used HTTPS even though cloudflared talks
    /// plain HTTP to us — tell the app so (X-Forwarded-Proto: https).
    var assumeHTTPS = false
    private var challenges: [String: String] = [:]

    var onState: ((State) -> Void)?
    var onHTTPSState: ((State) -> Void)?
    var onRequest: ((UUID?, String, String, String) -> Void)?   // service, host, request line, client IP

    func updateRoutes(_ newRoutes: [String: Route]) {
        routesLock.lock(); routes = newRoutes; routesLock.unlock()
    }

    func route(for host: String) -> Route? {
        routesLock.lock(); defer { routesLock.unlock() }
        return routes[host]
    }

    /// Let's Encrypt HTTP-01: token → key authorization.
    func setChallenge(_ token: String, _ value: String?) {
        routesLock.lock(); challenges[token] = value; routesLock.unlock()
    }

    func challenge(_ token: String) -> String? {
        routesLock.lock(); defer { routesLock.unlock() }
        return challenges[token]
    }

    /// Send plain-HTTP visitors to https:// for hosts the certificate covers.
    func setRedirect(_ enabled: Bool, httpsPort: Int) {
        routesLock.lock(); redirect = (enabled, httpsPort); routesLock.unlock()
    }

    var redirectSettings: (enabled: Bool, httpsPort: Int) {
        routesLock.lock(); defer { routesLock.unlock() }
        return redirect
    }

    func startHTTPS(port: Int, identity: sec_identity_t) {
        stopHTTPS()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            onHTTPSState?(.failed("Invalid port \(port)")); return
        }
        onHTTPSState?(.starting)
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, identity)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                ProxySession(client: conn, server: self, queue: self.queue, scheme: "https").start()
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onHTTPSState?(.listening(port))
                case .failed(let error):
                    self?.onHTTPSState?(.failed(Self.describe(error, port: port)))
                    l.cancel()
                default: break
                }
            }
            tlsListener = l
            l.start(queue: queue)
        } catch {
            onHTTPSState?(.failed(error.localizedDescription))
        }
    }

    func stopHTTPS() {
        tlsListener?.cancel()
        tlsListener = nil
        onHTTPSState?(.stopped)
    }

    /// `loopbackOnly`: listen on 127.0.0.1 only (Cloudflare mode — only
    /// cloudflared on this Mac may connect).
    func start(port: Int, loopbackOnly: Bool = false) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            onState?(.failed("Invalid port \(port)")); return
        }
        onState?(.starting)
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if loopbackOnly { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort) }
            let listener = loopbackOnly ? try NWListener(using: params) : try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                ProxySession(client: conn, server: self, queue: self.queue, scheme: "http").start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onState?(.listening(port))
                case .failed(let error):
                    self?.onState?(.failed(Self.describe(error, port: port)))
                    listener.cancel()
                case .cancelled: break
                default: break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onState?(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onState?(.stopped)
    }

    private static func describe(_ error: NWError, port: Int) -> String {
        if case .posix(let code) = error {
            if code == .EADDRINUSE { return "Port \(port) is already in use by another program." }
            if code == .EACCES { return "Not allowed to listen on port \(port)." }
        }
        return error.localizedDescription
    }
}

/// One client connection.
private final class ProxySession {
    private let client: NWConnection
    private weak var server: ProxyServer?
    private let queue: DispatchQueue
    private let scheme: String
    private var upstream: NWConnection?
    private var buffer = Data()
    private var closed = false
    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let maxHead = 64 * 1024

    init(client: NWConnection, server: ProxyServer, queue: DispatchQueue, scheme: String) {
        self.client = client
        self.server = server
        self.queue = queue
        self.scheme = scheme
    }

    func start() {
        client.stateUpdateHandler = { [self] state in
            if case .failed = state { close() }
        }
        client.start(queue: queue)
        readHead()
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Self.headEnd) {
                handleHead(headEnd: range.upperBound)
            } else if buffer.count > Self.maxHead {
                respond(431, "Request headers too large.")
            } else if isComplete || error != nil {
                close()
            } else {
                readHead()
            }
        }
    }

    private func handleHead(headEnd: Int) {
        let headData = buffer.prefix(headEnd)
        let rest = buffer.suffix(from: headEnd)
        guard let head = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            respond(400, "Bad request."); return
        }
        var lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { respond(400, "Bad request."); return }
        let requestLine = lines.removeFirst()

        var hostHeader = ""
        var isUpgrade = false
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("host:") {
                hostHeader = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("upgrade:") {
                isUpgrade = true
            }
        }
        let host = Self.stripPort(hostHeader).lowercased()

        // Let's Encrypt domain check, answered for any host
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let acmePrefix = "/.well-known/acme-challenge/"
        if scheme == "http", path.hasPrefix(acmePrefix) {
            let token = String(path.dropFirst(acmePrefix.count))
            if let value = server?.challenge(token) {
                server?.onRequest?(nil, "acme", "Let's Encrypt checked \(host)", Self.remoteIP(client.endpoint))
                let body = Data(value.utf8)
                var payload = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                payload.append(body)
                client.send(content: payload, completion: .contentProcessed { [self] _ in finish(client) })
            } else {
                respond(404, "Unknown challenge.")
            }
            return
        }

        guard let route = server?.route(for: host) else {
            server?.onRequest?(nil, host, requestLine, Self.remoteIP(client.endpoint))
            respond(404, host.isEmpty
                ? "No Host header in the request."
                : "OntuTunnel has no running service for <b>\(Self.escape(host))</b>.")
            return
        }
        server?.onRequest?(route.serviceID, host, "\(scheme.uppercased()) \(requestLine)", Self.remoteIP(client.endpoint))

        if scheme == "http", route.httpsAvailable, let settings = server?.redirectSettings, settings.enabled {
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let port = settings.httpsPort == 443 ? "" : ":\(settings.httpsPort)"
            redirect(to: "https://\(host)\(port)\(path.hasPrefix("/") ? path : "/")")
            return
        }

        // rebuild the head for the local app
        let clientIP = Self.remoteIP(client.endpoint)
        var out: [String] = [requestLine]
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("host:") {
                out.append("Host: \(route.hostOverride.isEmpty ? hostHeader : route.hostOverride)")
            } else if lower.hasPrefix("x-frappe-site-name:") || lower.hasPrefix("x-forwarded-") || lower.hasPrefix("x-real-ip:") {
                continue // never trust these from the internet
            } else if !isUpgrade && (lower.hasPrefix("connection:") || lower.hasPrefix("keep-alive:") || lower.hasPrefix("proxy-connection:")) {
                continue
            } else {
                out.append(line)
            }
        }
        if !route.frappeSite.isEmpty { out.append("X-Frappe-Site-Name: \(route.frappeSite)") }
        out.append("X-Forwarded-For: \(clientIP)")
        out.append("X-Real-IP: \(clientIP)")
        out.append("X-Forwarded-Proto: \(server?.assumeHTTPS == true ? "https" : scheme)")
        out.append("X-Forwarded-Host: \(hostHeader)")
        if !isUpgrade { out.append("Connection: close") }
        var payload = Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        payload.append(rest)

        let upstreamPort = route.socketPort > 0 && path.hasPrefix("/socket.io") ? route.socketPort : route.localPort
        connectUpstream(port: upstreamPort, initial: payload)
    }

    /// Dev servers listen on 127.0.0.1, ::1 or both — try IPv4 first,
    /// then IPv6, before telling the visitor the app is down.
    private static let loopbacks: [NWEndpoint.Host] = ["127.0.0.1", "::1"]

    private func connectUpstream(port: Int, initial: Data, attempt: Int = 0) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            respond(502, "Invalid local port."); return
        }
        let up = NWConnection(host: Self.loopbacks[attempt], port: nwPort, using: .tcp)
        upstream = up
        var started = false
        up.stateUpdateHandler = { [self] state in
            switch state {
            case .ready where !started:
                started = true
                up.send(content: initial, completion: .contentProcessed { [self] error in
                    if error != nil { close(); return }
                    pump(from: client, to: up)
                    pump(from: up, to: client)
                })
            case .waiting, .failed:
                if !started {
                    started = true
                    up.cancel()
                    if attempt + 1 < Self.loopbacks.count {
                        connectUpstream(port: port, initial: initial, attempt: attempt + 1)
                    } else {
                        respond(502, "The local app on port \(port) is not running.")
                    }
                } else {
                    close()
                }
            default: break
            }
        }
        up.start(queue: queue)
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if closed { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { [self] sendError in
                    if sendError != nil { close(); return }
                    if isComplete || error != nil { finish(to) } else { pump(from: from, to: to) }
                })
            } else if isComplete || error != nil {
                finish(to)
            } else {
                pump(from: from, to: to)
            }
        }
    }

    /// One side ended: flush the end to the other side, then tear down.
    private func finish(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            queue.asyncAfter(deadline: .now() + 0.2) { [self] in close() }
        })
    }

    private func redirect(to location: String) {
        let head = "HTTP/1.1 301 Moved Permanently\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in finish(client) })
    }

    private func respond(_ code: Int, _ message: String) {
        let reason = [400: "Bad Request", 404: "Not Found", 431: "Request Header Fields Too Large", 502: "Bad Gateway"][code] ?? "Error"
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(code) · OntuTunnel</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;background:#0b1220;color:#e6edf7;display:grid;place-items:center;min-height:100vh;margin:0}
        main{max-width:520px;padding:32px;text-align:center}h1{font-size:44px;margin:0 0 8px;color:#5b9dff}p{color:#a9b8d0;line-height:1.5}</style></head>
        <body><main><h1>\(code)</h1><p>\(message)</p><p style="font-size:13px">Served by OntuTunnel on the developer's Mac.</p></main></body></html>
        """
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyData)
        client.send(content: payload, completion: .contentProcessed { [self] _ in
            finish(client)
        })
    }

    private func close() {
        if closed { return }
        closed = true
        client.cancel()
        upstream?.cancel()
    }

    private static func stripPort(_ host: String) -> String {
        if host.hasPrefix("[") {   // [ipv6]:port
            return host.split(separator: "]").first.map { String($0.dropFirst()) } ?? host
        }
        return host.split(separator: ":").first.map(String.init) ?? host
    }

    private static func remoteIP(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
            case .name(let n, _): return n
            @unknown default: return "unknown"
            }
        }
        return "unknown"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
