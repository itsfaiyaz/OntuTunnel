import AppKit
import Foundation
import Network

/// The SSH tunnel: one `ssh -N -R …` process carrying every service.
/// For each service the server's 127.0.0.1:<remotePort> leads to this
/// Mac's localhost:<localPort>. Restarts itself if the connection drops,
/// and reconnects at once when the network changes (new Wi-Fi, new IP,
/// hotspot) or the Mac wakes up.
final class Tunnel {
    enum State: Equatable {
        case stopped
        case connecting
        case connected(Date)
        case failed(String)
    }

    var onState: ((State) -> Void)?
    var onLog: ((String, Bool) -> Void)?

    private var process: Process?
    private var wanted = false
    private var server = ServerConfig()
    private var forwards: [(remote: Int, local: Int)] = []
    private var retryDelay: TimeInterval = 3
    private var lastError = ""
    /// Bumped on every launch; a retry scheduled for an older launch is dropped.
    private var attempt = 0
    private var kick = 0
    private var networkSignature = ""
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ontutunnel.tunnel")

    var isRunning: Bool { process?.isRunning ?? false }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(path) }
        monitor.start(queue: queue)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reconnectSoon("Mac woke up") }
        }
    }

    func start(server: ServerConfig, forwards: [(remote: Int, local: Int)]) {
        queue.async { [self] in
            self.server = server
            self.forwards = forwards
            wanted = true
            retryDelay = 3
            stopProcess()
            launch()
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            attempt += 1
            stopProcess()
            onState?(.stopped)
        }
    }

    private func stopProcess() {
        if let p = process, p.isRunning {
            p.terminationHandler = nil
            p.terminate()
        }
        process = nil
    }

    // MARK: network changes

    private func networkChanged(_ path: NWPath) {
        let signature = Self.signature(path)
        defer { networkSignature = signature }
        guard !networkSignature.isEmpty, signature != networkSignature, wanted else { return }
        if path.status == .satisfied {
            reconnectSoon("Network changed")
        } else {
            onLog?("Network lost — will reconnect as soon as it's back", true)
        }
    }

    /// Interfaces, gateways and this Mac's IPv4 addresses: changes when the
    /// Wi-Fi, hotspot or IP changes, stays the same otherwise.
    private static func signature(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        return "\(path.status)|\(interfaces)|\(gateways)|\(localIPv4().joined(separator: ","))"
    }

    private static func localIPv4() -> [String] {
        var list: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cur = head
        while let p = cur {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    list.append(String(cString: host))
                }
            }
            cur = p.pointee.ifa_next
        }
        return list.sorted()
    }

    /// Restart the tunnel right away (after a short pause so a burst of
    /// network events causes one reconnect, not five).
    private func reconnectSoon(_ reason: String) {
        guard wanted, !forwards.isEmpty else { return }
        kick += 1
        let k = kick
        queue.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard k == kick, wanted else { return }
            onLog?("\(reason) — reconnecting now", false)
            retryDelay = 3
            stopProcess()
            launch()
        }
    }

    // MARK: ssh process

    private func launch() {
        guard wanted else { return }
        guard !forwards.isEmpty else { onState?(.failed("No services to tunnel yet.")); return }
        attempt += 1
        let thisAttempt = attempt
        onState?(.connecting)
        freeStalePorts()
        guard thisAttempt == attempt, wanted else { return }
        var extra = ["-N", "-T",
                     "-o", "ExitOnForwardFailure=yes",
                     "-o", "ServerAliveInterval=10",
                     "-o", "ServerAliveCountMax=3",
                     "-o", "TCPKeepAlive=yes"]
        for f in forwards {
            // bound to the server's loopback only — never reachable from the internet
            extra += ["-R", "127.0.0.1:\(f.remote):127.0.0.1:\(f.local)"]
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = RemoteServer.sshArgs(server, extra: extra)
        let err = Pipe()
        task.standardError = err
        task.standardOutput = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        lastError = ""
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let text = String(data: h.availableData, encoding: .utf8), !text.isEmpty else { return }
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                self?.lastError = String(line)
                self?.onLog?(String(line), true)
            }
        }
        task.terminationHandler = { [weak self] t in
            err.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                guard self.wanted, thisAttempt == self.attempt else { return }
                let why = self.lastError.isEmpty ? "connection closed (code \(t.terminationStatus))" : self.lastError
                self.onState?(.failed(why))
                self.onLog?("Tunnel dropped: \(why) — reconnecting in \(Int(self.retryDelay)) s", true)
                let delay = self.retryDelay
                self.retryDelay = min(self.retryDelay * 2, 30)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    guard thisAttempt == self.attempt else { return }
                    self.launch()
                }
            }
        }
        do {
            try task.run()
            process = task
            // ssh has no "connected" signal in -N mode: alive after a few seconds = up
            queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.process === task, task.isRunning else { return }
                self.retryDelay = 3
                self.onState?(.connected(Date()))
                self.onLog?("Tunnel up: " + self.forwards.map { "server:\($0.remote) → Mac:\($0.local)" }.joined(separator: ", "), false)
            }
        } catch {
            onState?(.failed(error.localizedDescription))
        }
    }

    /// Ends the server's leftover session from before a network change so the
    /// new tunnel can take the ports at once (instead of waiting minutes).
    private func freeStalePorts() {
        let script = RemoteServer.freeStalePortsScript(forwards.map(\.remote))
        let server = self.server
        final class Box: @unchecked Sendable { var out = "" }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.out = await RemoteServer.run(server, script, timeout: 15).out
            done.signal()
        }
        done.wait()
        if box.out.contains("freed") {
            onLog?("Closed the server's old connection from before the network change", false)
        }
    }
}
