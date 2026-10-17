import Foundation

/// The SSH tunnel: one `ssh -N -R …` process carrying every service.
/// For each service the server's 127.0.0.1:<remotePort> leads to this
/// Mac's localhost:<localPort>. Restarts itself if the connection drops.
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
    private let queue = DispatchQueue(label: "ontutunnel.tunnel")

    var isRunning: Bool { process?.isRunning ?? false }

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

    private func launch() {
        guard wanted else { return }
        guard !forwards.isEmpty else { onState?(.failed("No services to tunnel yet.")); return }
        onState?(.connecting)
        var extra = ["-N", "-T",
                     "-o", "ExitOnForwardFailure=yes",
                     "-o", "ServerAliveInterval=15",
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
                guard self.wanted else { return }
                let why = self.lastError.isEmpty ? "connection closed (code \(t.terminationStatus))" : self.lastError
                self.onState?(.failed(why))
                self.onLog?("Tunnel dropped: \(why) — reconnecting in \(Int(self.retryDelay)) s", true)
                let delay = self.retryDelay
                self.retryDelay = min(self.retryDelay * 2, 60)
                self.queue.asyncAfter(deadline: .now() + delay) { self.launch() }
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
}
